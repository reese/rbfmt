require_relative "test_helper"

class SnapshotTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @manifest_path = File.join(@root, "corpus.yml")
    @sha = "a" * 40
    File.write(
      @manifest_path,
      <<~YAML
        - name: sample
          url: https://example.com/sample
          sha: #{@sha}
          kind: gem
          tier: fast
          include: ["**/*.rb"]
          exclude: []
      YAML
    )
    @manifest = Corpus::Manifest.new(@manifest_path)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def result_set(files, config: {"header_mode" => "default", "checks" => %w[idempotence validity]})
    Corpus::ResultSet.new(
      manifest: @manifest,
      projects: [@manifest["sample"]],
      rubyfmt: {"path" => "/bin/rubyfmt", "sha256" => "b" * 64, "version" => "test"},
      config: config,
      files: files,
      duration_ms: 1,
      output_dir: nil
    )
  end

  def file(
    path,
    status: "ok",
    output: "abc",
    checks: {"idempotent" => true, "valid" => true},
    error: nil,
    error_kind: nil
  )
    Corpus::FileResult.new(
      repo: "sample",
      path: path,
      status: status,
      output_sha256: status == "ok" ? output : nil,
      error: error,
      error_kind: error_kind,
      error_sha256: error ? Digest::SHA256.hexdigest(error) : nil,
      exit_code: status == "ok" ? 0 : 1,
      duration_ms: 1,
      checks: checks
    )
  end

  def snapshot_from(files)
    Corpus::Snapshot.from_result_set(result_set(files))
  end

  def test_dump_is_sorted_and_roundtrips
    snapshot = snapshot_from([file("z.rb", output: "z"), file("a.rb", output: "a")])
    dumped = Corpus::Snapshot.dump(snapshot)
    assert_operator(dumped.index("\"a.rb\""), :<, dumped.index("\"z.rb\""))
    parsed = JSON.parse(dumped)
    assert(Corpus::Snapshot.validate!(parsed))
    assert_equal(snapshot["rollup"], parsed["rollup"])
    assert_equal(Corpus::Runner.prism_version, parsed["config"]["prism_version"])
    assert_includes(dumped, "\"a.rb\": {\"status\":\"ok\",\"output_sha256\":\"a\"}")
  end

  def test_comparison_reports_added_removed_and_changed
    old_snapshot = snapshot_from(
      [file("same.rb", output: "s"), file("gone.rb", output: "g"), file("changed.rb", output: "one")]
    )
    new_snapshot = snapshot_from(
      [file("same.rb", output: "s"), file("new.rb", output: "n"), file("changed.rb", output: "two")]
    )
    comparison = Corpus::Snapshot.compare(old_snapshot, new_snapshot, project_names: ["sample"])
    refute(comparison.clean?)
    assert_equal(1, comparison.added.length)
    assert_equal(1, comparison.removed.length)
    assert_equal(1, comparison.changed.length)
    assert_equal("changed.rb", comparison.changed.first.path)
    assert_equal("new.rb", comparison.added.first.path)
    assert_equal("gone.rb", comparison.removed.first.path)
  end

  def test_comparison_detects_new_error_and_check_failure
    old_snapshot = snapshot_from([file("a.rb", output: "a")])
    new_snapshot = snapshot_from([file("a.rb", status: "error", error: "boom", error_kind: "panic", checks: {})])
    comparison = Corpus::Snapshot.compare(old_snapshot, new_snapshot, project_names: ["sample"])
    assert_equal(1, comparison.new_errors.length)
    assert_equal("panic", comparison.new_errors.first.new_entry["error_kind"])

    old_snapshot = snapshot_from([file("a.rb", checks: {"idempotent" => true, "valid" => true})])
    new_snapshot = snapshot_from([file("a.rb", checks: {"idempotent" => false, "valid" => false})])
    comparison = Corpus::Snapshot.compare(old_snapshot, new_snapshot, project_names: ["sample"])
    assert_equal(1, comparison.idempotence_failures.length)
    assert_equal(1, comparison.validity_failures.length)
  end

  def test_validate_rejects_bad_rollup
    snapshot = snapshot_from([file("a.rb")])
    snapshot["repos"]["sample"]["rollup"] = "0" * 64
    assert_raises(Corpus::SnapshotError) { Corpus::Snapshot.validate!(snapshot) }
  end

  def test_merge_preserves_unselected_repos
    old_snapshot = snapshot_from([file("a.rb")])
    old_snapshot["repos"]["other"] = {
      "sha" => "b" * 40,
      "files" => {"other.rb" => {"status" => "ok", "output_sha256" => "x"}}
    }
    old_snapshot["repos"]["other"]["rollup"] = Corpus::Snapshot.repo_rollup(old_snapshot["repos"]["other"]["files"])
    Corpus::Snapshot.finalize!(old_snapshot)
    new_snapshot = snapshot_from([file("a.rb", output: "new")])
    merged = Corpus::Snapshot.merge(old_snapshot, new_snapshot)
    assert(merged["repos"].key?("other"))
    assert_equal("new", merged["repos"]["sample"]["files"]["a.rb"]["output_sha256"])
  end
end
