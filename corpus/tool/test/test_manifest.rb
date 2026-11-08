require_relative "test_helper"

class ManifestTest < Minitest::Test
  include CorpusTestHelpers

  def test_validates_and_selects_tiers
    Dir.mktmpdir do |root|
      _source, sha = make_repo(root, "lib/a.rb" => "x = 1\n")
      path = File.join(root, "corpus.yml")
      File.write(
        path,
        <<~YAML
          - name: fast_one
            url: file://#{root}/source
            sha: #{sha}
            kind: gem
            tier: fast
            include: ["**/*.rb"]
            exclude: []
          - name: full_one
            url: https://example.com/full
            sha: #{sha}
            kind: gem
            tier: full
            include: ["**/*.rb"]
            exclude: []
        YAML
      )
      manifest = Corpus::Manifest.new(path)
      assert(manifest.validate!)
      assert_equal(%w[fast_one], manifest.select(tier: "fast").map(&:name))
      assert_equal(%w[fast_one full_one], manifest.select(tier: "full").map(&:name))
      assert_equal(%w[fast_one full_one], manifest.select(tier: "all").map(&:name))
    end
  end

  def test_rejects_duplicate_names_and_bad_shas
    Dir.mktmpdir do |root|
      path = File.join(root, "corpus.yml")
      File.write(
        path,
        <<~YAML
          - name: same
            url: https://example.com/a
            sha: nope
            kind: gem
            tier: fast
            include: ["**/*.rb"]
            exclude: []
          - name: same
            url: https://example.com/b
            sha: #{"a" * 40}
            kind: nope
            tier: nope
            include: []
            exclude: []
        YAML
      )
      manifest = Corpus::Manifest.new(path)
      error = assert_raises(Corpus::ManifestError) { manifest.validate! }
      assert_includes(error.message, "duplicate")
      assert_includes(error.message, "sha must be")
      assert_includes(error.message, "kind must be")
    end
  end

  def test_bump_updates_only_the_sha_line
    Dir.mktmpdir do |root|
      source, sha_one = make_repo(root, "lib/a.rb" => "x = 1\n")
      File.write(File.join(source, "lib", "a.rb"), "x = 2\n")
      run_command("git", "-C", source, "add", ".")
      run_command("git", "-C", source, "commit", "--quiet", "-m", "second")
      sha_two = run_command("git", "-C", source, "rev-parse", "HEAD").strip

      path = File.join(root, "corpus.yml")
      File.write(
        path,
        <<~YAML
          # keep this comment
          - name: local
            url: file://#{source}
            sha: #{sha_one}
            kind: gem
            tier: fast
            include: &includes ["**/*.rb"]
            exclude: []
          - name: other
            url: https://example.com/other
            sha: #{sha_one}
            kind: gem
            tier: full
            include: *includes
            exclude: []
        YAML
      )
      before = File.read(path)
      manifest = Corpus::Manifest.new(path)
      old_sha, new_sha = manifest.bump("local", "HEAD")
      assert_equal(sha_one, old_sha)
      assert_equal(sha_two, new_sha)
      after = File.read(path)
      assert_includes(after, "# keep this comment")
      assert_includes(after, "include: &includes")
      assert_includes(after, "include: *includes")
      assert_equal(1, after.scan(/#{sha_two}/).length)
      assert_equal(1, after.scan(/#{sha_one}/).length)
      assert_equal(sha_two, Corpus::Manifest.new(path)["local"].sha)
    end
  end

  def test_glob_matching
    assert(Corpus::Glob.match?("**/*.rb", "a/b/c.rb"))
    assert(Corpus::Glob.match?("**/*.rb", "root.rb"))
    assert(Corpus::Glob.match?("**/fixtures/**", "spec/fixtures/data.rb"))
    assert(Corpus::Glob.match?("**/vendor/**", "a/vendor/b.rb"))
    assert(Corpus::Glob.match?("**/Rakefile", "Rakefile"))
    refute(Corpus::Glob.match?("**/*.rb", "a/b/c.txt"))
  end
end
