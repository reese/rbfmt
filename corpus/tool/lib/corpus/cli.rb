require "etc"
require "fileutils"
require "json"
require "optparse"
require "shellwords"

module Corpus
  class CLI
    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = @argv.shift
      case command
      when "validate"
        cmd_validate
      when "fetch"
        cmd_fetch
      when "bump"
        cmd_bump
      when "run"
        cmd_run
      when "check"
        cmd_check
      when "snapshot"
        cmd_snapshot
      when "compare"
        cmd_compare
      when "help", "-h", "--help", nil
        usage
        0
      else
        @stderr.puts("error: unknown command #{command.inspect}")
        usage
        2
      end

    rescue Corpus::Error, OptionParser::ParseError => e
      @stderr.puts("error: #{e.message}")
      1
    end

    private

    def cmd_validate
      opts = {manifest: Corpus::DEFAULT_MANIFEST_PATH, snapshot: Corpus::DEFAULT_SNAPSHOT_PATH, quiet: false}
      parser = OptionParser.new do |p|
        p.banner = "Usage: corpus validate [options]"
        p.on("--manifest PATH", "Path to corpus.yml") { |value| opts[:manifest] = value }
        p.on("--snapshot PATH", "Path to snapshot.json") { |value| opts[:snapshot] = value }
        p.on("--quiet", "Suppress output") { opts[:quiet] = true }
      end

      parse!(parser)

      manifest = Manifest.new(opts[:manifest])
      manifest.validate!
      if File.file?(opts[:snapshot])
        Snapshot.load(opts[:snapshot])
      end

      unless opts[:quiet]
        fast = manifest.projects.count(&:fast?)
        full = manifest.projects.length - fast
        @stdout.puts("ok: #{manifest.projects.length} projects (#{fast} fast, #{full} full)")
        @stdout.puts("snapshot: #{opts[:snapshot]}")
      end

      0
    end

    def cmd_fetch
      opts = base_options
      parser = OptionParser.new do |p|
        p.banner = "Usage: corpus fetch [options]"
        add_common_options(p, opts, default_tier: "all")
      end

      parse!(parser)

      manifest = load_manifest(opts)
      projects = select_projects(manifest, opts)
      cache = Cache.new(root: opts[:cache_root])
      cache.fetch_all(projects, jobs: opts[:jobs]) do |project, _dir|
        @stderr.puts("fetched #{project.name}@#{project.sha}") unless opts[:quiet]
      end

      @stdout.puts("fetched #{projects.length} project#{projects.length == 1 ? "" : "s"} into #{cache.repos_root}")
      0
    end

    def cmd_bump
      opts = {manifest: Corpus::DEFAULT_MANIFEST_PATH, quiet: false}
      parser = OptionParser.new do |p|
        p.banner = "Usage: corpus bump NAME [SHA_OR_REF] [options]"
        p.on("--manifest PATH", "Path to corpus.yml") { |value| opts[:manifest] = value }
        p.on("--quiet", "Suppress output") { opts[:quiet] = true }
      end

      parse!(parser)

      name = @argv.shift
      ref = @argv.shift
      raise OptionParser::InvalidArgument, "usage: corpus bump NAME [SHA_OR_REF]" if name.nil? || !@argv.empty?

      manifest = Manifest.new(opts[:manifest])
      manifest.validate!
      old_sha, new_sha = manifest.bump(name, ref)
      unless opts[:quiet]
        if old_sha == new_sha
          @stdout.puts("#{name}: already at #{new_sha}")
        else
          @stdout.puts("#{name}: #{old_sha} -> #{new_sha}")
        end
      end

      0
    end

    def cmd_run
      opts = base_options
      parser = OptionParser.new do |p|
        p.banner = "Usage: corpus run [options]"
        add_common_options(p, opts, default_tier: "all")
        p.on("--output-dir DIR", "Keep formatted output in DIR") { |value| opts[:output_dir] = value }
        p.on("--json PATH", "Write the result JSON to PATH (use - for stdout)") { |value| opts[:json] = value }
        p.on("--fail-on-error", "Exit non-zero if any file fails") { opts[:fail_on_error] = true }
      end

      parse!(parser)

      manifest = load_manifest(opts)
      projects = select_projects(manifest, opts)
      cache = Cache.new(root: opts[:cache_root])
      checks = opts[:checks] || Snapshot::CHECK_FIELDS
      output_dir = opts[:output_dir] && File.expand_path(opts[:output_dir])
      results = run_corpus(
        manifest: manifest,
        cache: cache,
        opts: opts,
        projects: projects,
        output_dir: output_dir,
        checks: checks
      )
      json = JSON.pretty_generate(results.to_h)
      if opts[:json] == "-"
        @stdout.puts(json)
      else
        File.write(File.expand_path(opts[:json]), json) if opts[:json]
        @stdout.puts(run_summary(results))
      end

      if opts[:fail_on_error] && results.files.any?(&:failed?)
        1
      else
        0
      end
    end

    def cmd_check
      opts = base_options
      opts[:report_dir] = File.join(Corpus::ROOT, "corpus-report")
      opts[:update] = false
      opts[:no_report] = false
      opts[:keep_output] = false
      opts[:full_checks] = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: corpus check [options]"
        add_common_options(p, opts, default_tier: "fast")
        p.on("--report-dir DIR", "Write the HTML/Markdown report to DIR") { |value| opts[:report_dir] = value }
        p.on("--update", "Update the snapshot instead of failing") { opts[:update] = true }
        p.on("--no-report", "Do not write the HTML report") { opts[:no_report] = true }
        p.on("--keep-output", "Keep formatted outputs alongside the report") { opts[:keep_output] = true }
        p.on("--full-checks", "Re-run idempotence/validity for unchanged files too") { opts[:full_checks] = true }
      end

      parse!(parser)

      manifest = load_manifest(opts)
      projects = select_projects(manifest, opts)
      snapshot_path = File.expand_path(opts[:snapshot])
      snapshot = Snapshot.load(snapshot_path) if File.file?(snapshot_path)
      if snapshot.nil? && !opts[:update]
        raise SnapshotError, "snapshot not found: #{snapshot_path}; run `ruby corpus/tool/corpus snapshot update`"
      end

      if snapshot
        expected_prism = snapshot.dig("config", "prism_version")
        current_prism = Runner.prism_version
        if expected_prism && current_prism.nil?
          raise SnapshotError, "the snapshot requires Prism #{expected_prism}, but Prism is not available in this Ruby"
        end

        if expected_prism && current_prism && expected_prism != current_prism
          expected_ruby = snapshot.dig("config", "ruby_version")
          raise(
            SnapshotError,
            "snapshot was generated with Prism #{expected_prism} (Ruby #{expected_ruby}); current Prism is #{current_prism}. Use the pinned Ruby or regenerate the snapshot with --replace."
          )
        end
      end

      checks = opts[:checks] || (snapshot && snapshot.dig("config", "checks")) || Snapshot::CHECK_FIELDS
      known_entries = if snapshot && !opts[:full_checks] && !opts[:update]
        snapshot["repos"].each_with_object({}) do |(repo, repo_data), entries|
          repo_data["files"].each { |path, entry| entries[[repo, path]] = entry }
        end
      end

      cache = Cache.new(root: opts[:cache_root])
      report_dir = File.expand_path(opts[:report_dir])
      FileUtils.rm_rf(report_dir)
      FileUtils.mkdir_p(report_dir)
      output_dir = if opts[:no_report] || opts[:update]
        nil
      else
        File.join(report_dir, "outputs")
      end

      results = run_corpus(
        manifest: manifest,
        cache: cache,
        opts: opts,
        projects: projects,
        output_dir: output_dir,
        checks: checks,
        known_entries: known_entries
      )
      File.write(File.join(report_dir, "results.json"), JSON.pretty_generate(results.to_h))
      new_snapshot = Snapshot.from_result_set(results)

      if opts[:update]
        merged = snapshot ? Snapshot.merge(snapshot, new_snapshot) : new_snapshot
        Snapshot.write(snapshot_path, merged)
        @stdout.puts("updated #{snapshot_path}")
        return 0
      end

      comparison = Snapshot.compare(snapshot, new_snapshot, project_names: projects.map(&:name))
      report = snapshot_report(
        comparison,
        results,
        manifest,
        cache,
        projects,
        opts,
        reuse_checks: !opts[:full_checks] && !opts[:update]
      )
      summary = report.summary
      unless opts[:no_report]
        report.write(report_dir)
        FileUtils.rm_rf(output_dir) if output_dir && !opts[:keep_output]
      end

      if comparison.clean?
        @stdout.puts("corpus snapshot matches (#{results.files.length} files, #{results.projects.length} projects).")
        return 0
      end

      @stdout.puts(summary)
      @stdout.puts
      @stdout.puts("report: #{File.join(report_dir, "report.html")}") unless opts[:no_report]
      print_changed_files(comparison)
      1
    end

    def cmd_snapshot
      subcommand = @argv.shift
      case subcommand
      when "update"
        cmd_snapshot_update
      when nil, "help", "-h", "--help"
        @stdout.puts("Usage: corpus snapshot update [options]")
        0
      else
        raise OptionParser::InvalidArgument, "unknown snapshot subcommand #{subcommand.inspect}"
      end
    end

    def cmd_snapshot_update
      opts = base_options
      opts[:replace] = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: corpus snapshot update [options]"
        add_common_options(p, opts, default_tier: "all")
        p.on("--replace", "Replace the snapshot instead of merging a partial selection") { opts[:replace] = true }
      end

      parse!(parser)

      manifest = load_manifest(opts)
      projects = select_projects(manifest, opts)
      snapshot_path = File.expand_path(opts[:snapshot])
      cache = Cache.new(root: opts[:cache_root])
      checks = opts[:checks] || Snapshot::CHECK_FIELDS
      results = run_corpus(
        manifest: manifest,
        cache: cache,
        opts: opts,
        projects: projects,
        output_dir: nil,
        checks: checks
      )
      new_snapshot = Snapshot.from_result_set(results)
      if File.file?(snapshot_path) && !opts[:replace] && projects.length < manifest.projects.length
        old_snapshot = Snapshot.load(snapshot_path)
        if old_snapshot["config"] != new_snapshot["config"]
          @stderr.puts("warning: snapshot config changed; old projects may need a full refresh")
        end

        new_snapshot = Snapshot.merge(old_snapshot, new_snapshot)
      end

      Snapshot.write(snapshot_path, new_snapshot)
      @stdout.puts(
        "updated #{snapshot_path} (#{new_snapshot["repos"].length} projects, #{new_snapshot["repos"].values.sum { |repo| repo["files"].length }} files)"
      )
      0
    end

    def cmd_compare
      opts = base_options
      opts[:base] = nil
      opts[:head] = nil
      opts[:path] = nil
      opts[:only_changed] = false
      opts[:limit] = 0
      opts[:no_build] = false
      opts[:no_fail] = false
      opts[:report_dir] = File.join(Corpus::ROOT, "corpus-report", "compare")
      parser = OptionParser.new do |p|
        p.banner = "Usage: corpus compare [options]"
        add_common_options(p, opts, default_tier: "all")
        p.on("--base REF_OR_BINARY", "Baseline git ref or rubyfmt binary (default: main/trunk merge-base)") { |value|
          opts[:base] = value
        }
        p.on("--head REF_OR_BINARY", "Head git ref or rubyfmt binary (default: working tree)") { |value|
          opts[:head] = value
        }
        p.on("--path GLOB", "Only report paths matching GLOB") { |value| opts[:path] = value }
        p.on("--only-changed", "Only report files whose output or status changed") { opts[:only_changed] = true }
        p.on("--limit N", Integer, "Only include the first N changed files in the report") { |value|
          opts[:limit] = value
        }
        p.on("--report-dir DIR", "Write the HTML/Markdown report to DIR") { |value| opts[:report_dir] = value }
        p.on("--no-build", "Do not build; use existing/cached binaries") { opts[:no_build] = true }
        p.on("--no-fail", "Exit zero even when differences are found") { opts[:no_fail] = true }
      end

      parse!(parser)

      manifest = load_manifest(opts)
      projects = select_projects(manifest, opts)
      cache = Cache.new(root: opts[:cache_root])
      base_spec = opts[:base] || Binary.default_base_ref(Corpus::ROOT)
      head_spec = opts[:head] || opts[:rubyfmt] || "working"
      base_binary = Binary.resolve(
        base_spec,
        repo_root: Corpus::ROOT,
        cache: cache,
        role: "base",
        no_build: opts[:no_build]
      )
      head_binary = Binary.resolve(
        head_spec,
        repo_root: Corpus::ROOT,
        cache: cache,
        role: "head",
        no_build: opts[:no_build]
      )
      checks = opts[:checks] || Snapshot::CHECK_FIELDS
      comparison = Compare
        .new(
          manifest: manifest,
          projects: projects,
          cache: cache,
          base_binary: base_binary,
          head_binary: head_binary,
          jobs: opts[:jobs],
          timeout: opts[:timeout],
          header_mode: opts[:header_mode],
          checks: checks,
          refresh: opts[:refresh],
          repo_names: opts[:repos],
          path_glob: opts[:path],
          limit: opts[:limit]
        )
        .run
      report_dir = File.expand_path(opts[:report_dir])
      FileUtils.rm_rf(report_dir)
      report = comparison.report
      summary = report.write(report_dir)
      File.write(
        File.join(report_dir, "comparison.json"),
        JSON.pretty_generate(
          {
            "base" => comparison.base_label,
            "head" => comparison.head_label,
            "changed" => comparison.changed?,
            "changes" => comparison.all_changes.map do |change|
              {"repo" => change.repo, "path" => change.path, "kind" => change.kind.to_s, "notes" => change.notes}
            end
          }
        )
      )
      @stdout.puts(summary)
      @stdout.puts
      @stdout.puts("report: #{File.join(report_dir, "report.html")}")
      if comparison.changed?
        @stdout.puts(
          "changed: #{comparison.all_changes.length} file#{comparison.all_changes.length == 1 ? "" : "s"} across #{comparison.all_changes.map(&:repo).uniq.length} project#{comparison.all_changes.map(&:repo).uniq.length == 1 ? "" : "s"}"
        )
        opts[:no_fail] ? 0 : 1
      else
        @stdout.puts("no differences")
        0
      end
    end

    def base_options
      {
        manifest: Corpus::DEFAULT_MANIFEST_PATH,
        snapshot: Corpus::DEFAULT_SNAPSHOT_PATH,
        cache_root: Corpus::DEFAULT_CACHE_ROOT,
        repos: [],
        tier: "all",
        jobs: Etc.nprocessors,
        timeout: 10.0,
        header_mode: "default",
        checks: nil,
        rubyfmt: nil,
        quiet: false,
        refresh: false
      }
    end

    def add_common_options(parser, opts, default_tier:)
      opts[:tier] = default_tier
      opts[:repos] = []
      parser.on("--repo NAME", "Limit to a project (repeatable)") { |value| opts[:repos] << value }
      parser
        .on("--tier TIER", %w[fast full all], "Select fast, full, or all projects (default: #{default_tier})") { |value|
          opts[:tier] = value
        }
      parser.on("--jobs N", Integer, "Parallel jobs (default: CPU count)") { |value| opts[:jobs] = value }
      parser.on("--timeout SECONDS", Float, "Per-file timeout (default: 10)") { |value| opts[:timeout] = value }
      parser.on("--header-mode MODE", %w[default opt-in opt-out], "Header comment mode (default: default)") { |value|
        opts[:header_mode] = value
      }
      parser.on("--checks LIST", "idempotence,validity,ast or none (default: idempotence,validity)") { |value|
        opts[:checks] = parse_checks(value)
      }
      parser.on("--rubyfmt PATH", "rubyfmt binary to test") { |value| opts[:rubyfmt] = value }
      parser.on("--cache-root DIR", "Corpus cache directory (default: ~/.cache/rubyfmt-corpus)") { |value|
        opts[:cache_root] = value
      }
      parser.on("--manifest PATH", "Path to corpus.yml") { |value| opts[:manifest] = value }
      parser.on("--snapshot PATH", "Path to snapshot.json") { |value| opts[:snapshot] = value }
      parser.on("--refresh", "Ignore cached run results") { opts[:refresh] = true }
      parser.on("--quiet", "Suppress progress output") { opts[:quiet] = true }
    end

    def parse!(parser)
      parser.parse!(@argv)
    rescue OptionParser::ParseError => e
      @stderr.puts("error: #{e.message}")
      @stderr.puts(parser)
      raise
    end

    def parse_checks(value)
      return [] if value.nil? || value.strip.empty? || value.strip == "none"

      checks = value.split(",").map(&:strip).reject(&:empty?)
      unknown = checks - Runner::ALLOWED_CHECKS
      raise OptionParser::InvalidArgument, "unknown checks: #{unknown.join(", ")}" unless unknown.empty?

      checks.sort
    end

    def load_manifest(opts)
      manifest = Manifest.new(opts[:manifest])
      manifest.validate!
      manifest
    end

    def select_projects(manifest, opts)
      manifest.select(names: opts[:repos], tier: opts[:tier])
    end

    def rubyfmt_path(opts)
      candidate = opts[:rubyfmt] || ENV["RUBYFMT"] || File.join(Corpus::ROOT, "target", "release", "rubyfmt-main")
      path = File.expand_path(candidate)
      unless File.file?(path) && File.executable?(path)
        raise(
          RunnerError,
          "rubyfmt binary not found or not executable: #{path}; run `cargo build --release` or pass --rubyfmt PATH"
        )
      end

      path
    end

    def run_corpus(manifest:, cache:, opts:, projects:, output_dir:, checks:, known_entries: nil)
      Runner
        .new(
          rubyfmt: rubyfmt_path(opts),
          manifest: manifest,
          projects: projects,
          cache: cache,
          jobs: opts[:jobs],
          timeout: opts[:timeout],
          header_mode: opts[:header_mode],
          checks: checks,
          output_dir: output_dir,
          progress: !opts[:quiet],
          fetch: true,
          fetch_jobs: opts[:jobs],
          known_entries: known_entries
        )
        .run
    end

    def run_summary(results)
      counts = Hash.new(0)
      results.files.each { |file| counts[file.status] += 1 }
      parts = %w[ok error timeout skipped].map { |status| "#{counts[status]} #{status}" }
      lines = [
        "formatted #{results.files.length} files in #{format_duration(results.duration_ms)}: #{parts.join(", ")}"
      ]
      errors = results.files.select(&:failed?).group_by(&:error_kind).transform_values(&:length)
      lines << "errors: #{errors.sort.map { |kind, count| "#{kind}=#{count}" }.join(", ")}" unless errors.empty?
      lines.join("\n")
    end

    def snapshot_report(comparison, results, manifest, cache, projects, opts, reuse_checks: true)
      total_files = projects.to_h { |project| [project.name, results.files_for(project.name).length] }
      repos = projects.map do |project|
        Report::RepoInfo.new(
          name: project.name,
          url: project.url,
          slug: project.github_slug,
          base_sha: comparison.old_snapshot.dig("repos", project.name, "sha"),
          head_sha: comparison.new_snapshot.dig("repos", project.name, "sha"),
          tier: project.tier
        )
      end

      files = comparison.diffs.map do |diff|
        new_result = results.find(diff.repo, diff.path)
        project = manifest[diff.repo]
        input = project ? read_input(cache, project, diff.path) : nil
        new_output = read_result_output(results, new_result)
        diff_text = if new_output && input
          Diff.unified(input, new_output, "input/#{diff.path}", "formatted/#{diff.path}")
        elsif new_output
          Diff.unified("", new_output, "/dev/null", "formatted/#{diff.path}")
        end

        old_entry = diff.old_entry&.dup
        new_entry = diff.new_entry&.dup
        new_entry["error"] = new_result.error if new_entry && new_result&.error
        Report::ReportFile.new(
          repo: diff.repo,
          path: diff.path,
          kind: diff.kind,
          old_status: old_entry && old_entry["status"],
          new_status: new_entry && new_entry["status"],
          old_entry: old_entry,
          new_entry: new_entry,
          old_output: nil,
          new_output: new_output,
          input: input,
          base_sha: comparison.old_snapshot.dig("repos", diff.repo, "sha"),
          head_sha: comparison.new_snapshot.dig("repos", diff.repo, "sha"),
          diff: diff_text,
          changed_lines: diff_text ? Diff.changed_lines(input || "", new_output || "") : [],
          notes: snapshot_notes(diff, new_result)
        )
      end

      notes = []
      notes <<
        "The snapshot stores hashes, not formatted output. Where no baseline output is available, the diff compares the input file with its new formatted output."
      if reuse_checks
        notes <<
          "Unchanged files reuse the snapshot's idempotence/validity results. Run `check --full-checks` to re-check every file."
      end

      if Corpus::Runner.prism_version
        notes << "Validity checked with Ruby #{RUBY_VERSION} / Prism #{Corpus::Runner.prism_version}."
      end

      comparison.sha_changes.each do |name, old_sha, new_sha|
        notes << "project #{name}: #{old_sha[0, 12]} -> #{new_sha[0, 12]}"
      end

      comparison.config_changes.each do |field, old_value, new_value|
        notes << "config #{field}: #{old_value.inspect} -> #{new_value.inspect}"
      end

      update = "ruby corpus/tool/corpus snapshot update --rubyfmt #{Shellwords.escape(rubyfmt_path(opts))} --tier #{opts[:tier]}"
      Report.new(
        title: "rubyfmt corpus snapshot check",
        mode: "check",
        files: files,
        repos: repos,
        total_files: total_files,
        update_command: update,
        base_label: "snapshot",
        head_label: "working tree",
        notes: notes,
        total_changes: comparison.diffs.length,
        show_update: !comparison.clean?
      )
    end

    def snapshot_notes(diff, new_result)
      notes = []
      notes << "added" if diff.kind == :added
      notes << "removed" if diff.kind == :removed
      if diff.old_entry && diff.new_entry
        old_status = diff.old_entry["status"]
        new_status = diff.new_entry["status"]
        notes << "status #{old_status} -> #{new_status}" if old_status != new_status
        if diff.old_entry["output_sha256"] &&
            diff.new_entry["output_sha256"] &&
            diff.old_entry["output_sha256"] != diff.new_entry["output_sha256"]
          notes << "output hash changed"
        end

        if diff.new_entry["idempotent"] == false && diff.old_entry["idempotent"] != false
          notes << "idempotence: pass -> fail"
        end

        if diff.new_entry["valid"] == false && diff.old_entry["valid"] != false
          notes << "validity: pass -> fail"
        end
      end

      notes << "new error: #{truncate_error(new_result.error)}" if new_result&.error
      notes
    end

    def read_input(cache, project, path)
      file = File.join(cache.repo_dir(project), path)
      File.file?(file) ? File.binread(file) : nil
    rescue StandardError
      nil
    end

    def read_result_output(results, result)
      return nil unless result&.ok? && results.output_dir

      file = File.join(results.output_dir, result.repo, result.path)
      File.file?(file) ? File.binread(file) : nil
    end

    def truncate_error(text, length = 240)
      value = text.to_s.gsub(/\s+/, " ").strip
      value.length > length ? "#{value[0, length]}..." : value
    end

    def print_changed_files(comparison)
      files = comparison.diffs.first(50)
      return if files.empty?

      @stdout.puts("changed files:")
      files.each do |diff|
        fields = diff.changed_fields.join(", ")
        @stdout.puts("  #{diff.repo}/#{diff.path} (#{diff.kind}#{fields.empty? ? "" : ": #{fields}"})")
      end

      remaining = comparison.diffs.length - files.length
      @stdout.puts("  ... and #{remaining} more") if remaining.positive?
    end

    def format_duration(milliseconds)
      format("%.2fs", milliseconds / 1000.0)
    end

    def usage
      @stdout.puts(
        <<~TEXT
          Usage: ruby corpus/tool/corpus <command> [options]

          Commands:
            validate               Validate corpus.yml and snapshot.json
            fetch                  Fetch pinned corpus repositories
            bump NAME [SHA_OR_REF] Update a pinned project (defaults to remote HEAD)
            run                    Format the corpus and write a result JSON
            check                  Compare the corpus to the committed snapshot
            snapshot update        Regenerate the committed snapshot
            compare                Compare two rubyfmt binaries (default: base ref vs working tree)

          Common options:
            --repo NAME            Limit to a project (repeatable)
            --tier fast|full|all   Select a corpus tier
            --jobs N               Parallel formatting jobs
            --timeout SECONDS      Per-file timeout
            --header-mode MODE     default, opt-in, or opt-out
            --checks LIST          idempotence,validity,ast, or none
            --rubyfmt PATH         rubyfmt binary
            --cache-root DIR       Corpus cache directory
            --manifest PATH        corpus.yml path
            --snapshot PATH        snapshot.json path

          Examples:
            ruby corpus/tool/corpus validate
            ruby corpus/tool/corpus fetch --tier fast
            ruby corpus/tool/corpus snapshot update --rubyfmt target/release/rubyfmt-main
            ruby corpus/tool/corpus check --tier fast --rubyfmt target/release/rubyfmt-main
            ruby corpus/tool/corpus compare
        TEXT
      )
    end
  end
end
