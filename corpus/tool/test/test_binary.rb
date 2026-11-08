require_relative "test_helper"

class BinaryTest < Minitest::Test
  include CorpusTestHelpers

  def setup
    @root = Dir.mktmpdir
    @source, = make_repo(@root, "lib/a.rb" => "x = 1\n")
    @cache = Corpus::Cache.new(root: File.join(@root, "cache"))
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_resolves_a_prebuilt_binary_path
    binary = File.join(@root, "rubyfmt")
    File.write(binary, "#!/usr/bin/env ruby\n")
    File.chmod(0o755, binary)
    resolved = Corpus::Binary.resolve(binary, repo_root: @source, cache: @cache, role: "base")
    assert_equal(File.expand_path(binary), resolved.path)
  end

  def test_treats_a_git_ref_as_a_ref
    error = assert_raises(Corpus::BuildError) do
      Corpus::Binary.resolve("HEAD", repo_root: @source, cache: @cache, role: "base", no_build: true)
    end

    assert_includes(error.message, "no cached build for base HEAD")
  end

  def test_missing_remote_ref_suggests_fetching
    error = assert_raises(Corpus::BuildError) do
      Corpus::Binary.resolve("origin/main", repo_root: @source, cache: @cache, role: "base", no_build: true)
    end

    assert_includes(error.message, "could not resolve git ref")
    assert_includes(error.message, "git fetch origin")
    refute_includes(error.message, "binary not found")
  end

  def test_missing_path_inside_an_existing_directory
    FileUtils.mkdir_p(File.join(@source, "target", "release"))
    error = assert_raises(Corpus::BuildError) do
      Corpus::Binary.resolve("target/release/missing", repo_root: @source, cache: @cache, role: "base", no_build: true)
    end

    assert_includes(error.message, "must be a git ref or an existing binary")
  end
end
