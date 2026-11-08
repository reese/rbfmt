$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "corpus"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

module CorpusTestHelpers
  def run_command(*command, chdir: nil)
    options = chdir ? {chdir: chdir} : {}
    out, err, status = Open3.capture3(*command, **options)
    raise "#{command.join(" ")} failed: #{err}" unless status.success?

    out
  end

  def make_repo(root, files)
    source = File.join(root, "source")
    run_command("git", "init", "--quiet", source)
    run_command("git", "-C", source, "config", "user.email", "corpus@example.com")
    run_command("git", "-C", source, "config", "user.name", "Corpus Test")
    files.each do |relative, content|
      destination = File.join(source, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, content)
    end

    run_command("git", "-C", source, "add", ".")
    run_command("git", "-C", source, "commit", "--quiet", "-m", "fixture")
    [source, run_command("git", "-C", source, "rev-parse", "HEAD").strip]
  end

  def write_manifest(path, name:, url:, sha:, include_globs: ["**/*.rb"], exclude_globs: [])
    File.write(
      path,
      <<~YAML
        - name: #{name}
          url: #{url}
          sha: #{sha}
          kind: gem
          tier: fast
          include: #{include_globs.inspect}
          exclude: #{exclude_globs.inspect}
      YAML
    )
  end

  def fake_rubyfmt(root, name, body)
    path = File.join(root, name)
    File.write(
      path,
      <<~RUBY
        #!/usr/bin/env ruby
        #{body}
      RUBY
    )
    File.chmod(0o755, path)
    path
  end
end
