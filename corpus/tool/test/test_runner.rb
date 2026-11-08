require_relative "test_helper"

class RunnerTest < Minitest::Test
  include CorpusTestHelpers

  def setup
    @root = Dir.mktmpdir
    @source, @sha = make_repo(
      @root,
      "lib/good.rb" => "def x(a,b)\n a+b\nend\n",
      "lib/other.rb" => "def y\n 1\nend\n",
      "lib/skip.rb" => "# rubyfmt: false\ndef skip( a )\n a\nend\n",
      "lib/optin.rb" => "# rubyfmt: true\ndef optin( a )\n a\nend\n",
      "spec/fixtures/ignored.rb" => "def x(\n"
    )
    @manifest_path = File.join(@root, "corpus.yml")
    write_manifest(
      @manifest_path,
      name: "local",
      url: "file://#{@source}",
      sha: @sha,
      exclude_globs: ["**/fixtures/**"]
    )
    @manifest = Corpus::Manifest.new(@manifest_path)
    @manifest.validate!
    @cache = Corpus::Cache.new(root: File.join(@root, "cache"))
    @output = File.join(@root, "out")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def runner(binary, **options)
    Corpus::Runner.new(
      rubyfmt: binary,
      manifest: @manifest,
      projects: [@manifest["local"]],
      cache: @cache,
      jobs: 2,
      timeout: options.delete(:timeout) || 1,
      progress: false,
      **options
    )
  end

  def passthrough(root, name = "passthrough", body: "print STDIN.read")
    fake_rubyfmt(
      root,
      name,
      <<~RUBY
        if ARGV.include?("--version")
          puts "fake 1.0"
          exit 0
        end
        #{body}
      RUBY
    )
  end

  def test_runs_files_and_keeps_output
    binary = passthrough(@root)
    result = runner(binary, output_dir: @output, checks: %w[idempotence validity]).run
    assert_equal(4, result.files.length)
    assert(result.files.all? { |file| file.status == "ok" })
    assert(result.files.all? { |file| file.checks["idempotent"] })
    assert(result.files.all? { |file| file.checks["valid"] }) if Corpus::Runner.prism_version
    refute(result.files.any? { |file| file.path.include?("fixtures") })
    assert(File.file?(File.join(@output, "local", "lib", "good.rb")))
    assert(result.to_h["projects"].first["files"].is_a?(Array))
  end

  def test_error_on_one_file_does_not_abort
    binary = fake_rubyfmt(
      @root,
      "error",
      <<~'RUBY'
        if ARGV.include?("--version")
          puts "fake 1.0"
          exit 0
        end
        STDERR.puts "Error! source: stdin"
        STDERR.puts "Rubyfmt detected a syntax error in the ruby code being executed"
        exit 1
      RUBY
    )
    result = runner(binary, checks: []).run
    assert_equal(4, result.files.length)
    assert(result.files.all? { |file| file.status == "error" })
    assert(result.files.all? { |file| file.error_kind == "syntax_error" })
  end

  def test_timeout_is_reported_for_only_the_file
    binary = fake_rubyfmt(
      @root,
      "slow",
      <<~'RUBY'
        if ARGV.include?("--version")
          puts "fake 1.0"
          exit 0
        end
        sleep 5
      RUBY
    )
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = runner(binary, timeout: 0.3, checks: []).run
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal(4, result.files.length)
    assert(result.files.all? { |file| file.status == "timeout" })
    assert(result.files.all? { |file| file.error_kind == "timeout" })
    assert_operator(elapsed, :<, 5)
  end

  def test_panic_is_reported
    binary = fake_rubyfmt(
      @root,
      "panic",
      <<~'RUBY'
        if ARGV.include?("--version")
          puts "fake 1.0"
          exit 0
        end
        STDERR.puts "thread 'main' panicked at librubyfmt/src/format_prism.rs:1:1: boom"
        exit 101
      RUBY
    )
    result = runner(binary, checks: []).run
    assert(result.files.all? { |file| file.status == "error" })
    assert(result.files.all? { |file| file.error_kind == "panic" })
  end

  def test_header_opt_out_skips_files_with_false_header
    binary = passthrough(@root)
    result = runner(binary, header_mode: "opt-out", checks: []).run
    skipped = result.files.select { |file| file.status == "skipped" }
    assert_equal(["lib/skip.rb"], skipped.map(&:path))
  end

  def test_header_opt_in_skips_files_without_true_header
    binary = passthrough(@root)
    result = runner(binary, header_mode: "opt-in", checks: []).run
    formatted = result.files.select { |file| file.status == "ok" }
    skipped = result.files.select { |file| file.status == "skipped" }
    assert_equal(["lib/optin.rb"], formatted.map(&:path))
    assert_equal(3, skipped.length)
  end

  def test_idempotence_failure
    binary = fake_rubyfmt(
      @root,
      "nonidempotent",
      <<~'RUBY'
        if ARGV.include?("--version")
          puts "fake 1.0"
          exit 0
        end
        print STDIN.read + " "
      RUBY
    )
    result = runner(binary, checks: %w[idempotence]).run
    assert(result.files.all? { |file| file.checks["idempotent"] == false })
  end

  def test_validity_failure
    skip("Prism is not available") unless Corpus::Runner.prism_version

    binary = fake_rubyfmt(
      @root,
      "invalid",
      <<~'RUBY'
        if ARGV.include?("--version")
          puts "fake 1.0"
          exit 0
        end
        print "def x(\n"
      RUBY
    )
    result = runner(binary, checks: %w[validity]).run
    assert(result.files.all? { |file| file.checks["valid"] == false })
  end

  def test_result_set_roundtrip
    binary = passthrough(@root)
    result = runner(binary, output_dir: @output, checks: %w[idempotence validity]).run
    data = JSON.parse(JSON.generate(result.to_h))
    loaded = Corpus::ResultSet.from_h(data, manifest: @manifest, output_dir: @output)
    assert_equal(result.files.length, loaded.files.length)
    assert_equal(result.files.map(&:path), loaded.files.map(&:path))
    assert_equal(result.rollup, loaded.rollup)
  end

  def test_snapshot_is_deterministic
    binary = passthrough(@root)
    first = runner(binary, checks: %w[idempotence validity]).run
    second = runner(binary, checks: %w[idempotence validity]).run
    first_snapshot = Corpus::Snapshot.from_result_set(first)
    second_snapshot = Corpus::Snapshot.from_result_set(second)
    assert_equal(Corpus::Snapshot.dump(first_snapshot), Corpus::Snapshot.dump(second_snapshot))
  end
end

class RunnerKnownChecksTest < Minitest::Test
  include CorpusTestHelpers

  def setup
    @root = Dir.mktmpdir
    @source, @sha = make_repo(@root, "lib/good.rb" => "def x(a,b)\n a+b\nend\n")
    @manifest_path = File.join(@root, "corpus.yml")
    write_manifest(
      @manifest_path,
      name: "local",
      url: "file://#{@source}",
      sha: @sha,
      include_globs: ["lib/**/*.rb"]
    )
    @manifest = Corpus::Manifest.new(@manifest_path)
    @manifest.validate!
    @cache = Corpus::Cache.new(root: File.join(@root, "cache"))
    @log = File.join(@root, "runs.log")
    @binary = fake_rubyfmt(
      @root,
      "logging-rubyfmt",
      <<~RUBY
        if ARGV.include?("--version")
          puts "fake 1.0"
          exit 0
        end
        File.open(#{@log.inspect}, "a") { |file| file.puts "run" }
        print STDIN.read
      RUBY
    )
    @input = File.binread(File.join(@source, "lib", "good.rb"))
    @sha256 = Digest::SHA256.hexdigest(@input)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def run_corpus(known_entries)
    Corpus::Runner
      .new(
        rubyfmt: @binary,
        manifest: @manifest,
        projects: [@manifest["local"]],
        cache: @cache,
        jobs: 1,
        timeout: 1,
        progress: false,
        checks: %w[idempotence],
        known_entries: known_entries
      )
      .run
  end

  def test_unchanged_output_reuses_known_checks_without_second_run
    result = run_corpus(
      ["local", "lib/good.rb"] => {
        "status" => "ok",
        "output_sha256" => @sha256
      }
    )
    file = result.files.first
    assert_equal("ok", file.status)
    refute(file.checks.key?("idempotent"))
    assert_equal(1, File.readlines(@log).length)
  end

  def test_unchanged_output_copies_known_failure
    result = run_corpus(
      ["local", "lib/good.rb"] => {
        "status" => "ok",
        "output_sha256" => @sha256,
        "idempotent" => false
      }
    )
    file = result.files.first
    assert_equal(false, file.checks["idempotent"])
    assert_equal(1, File.readlines(@log).length)
  end

  def test_changed_output_runs_checks
    result = run_corpus(
      ["local", "lib/good.rb"] => {
        "status" => "ok",
        "output_sha256" => "0" * 64
      }
    )
    file = result.files.first
    assert_equal(true, file.checks["idempotent"])
    assert_equal(2, File.readlines(@log).length)
  end
end
