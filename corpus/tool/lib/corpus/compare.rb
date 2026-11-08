require "digest"
require "fileutils"
require "json"

module Corpus
  class CompareError < Error
  end

  class FileChange
    attr_reader :repo, :path, :base, :head, :base_output, :head_output, :diff, :changed_lines, :notes

    def initialize(repo:, path:, base:, head:, base_output:, head_output:, diff:, changed_lines:, notes:)
      @repo = repo
      @path = path
      @base = base
      @head = head
      @base_output = base_output
      @head_output = head_output
      @diff = diff
      @changed_lines = changed_lines
      @notes = notes
    end

    def kind
      return :added if base.nil?
      return :removed if head.nil?

      :changed
    end

    def old_status
      base&.status
    end

    def new_status
      head&.status
    end

    def old_entry
      entry = base&.snapshot_entry
      entry["error"] = base.error if entry && base.error
      entry
    end

    def new_entry
      entry = head&.snapshot_entry
      entry["error"] = head.error if entry && head.error
      entry
    end

    def base_sha
      nil
    end

    def head_sha
      nil
    end

    def changed?
      return true if base.nil? || head.nil?
      return true if base.status != head.status
      return true if base.output_sha256 != head.output_sha256
      return true if base.error_sha256 != head.error_sha256
      return true if base.error_kind != head.error_kind
      return true if base.checks["idempotent"] != head.checks["idempotent"]
      return true if base.checks["valid"] != head.checks["valid"]

      false
    end
  end

  class Comparison
    attr_reader(
      :base,
      :head,
      :projects,
      :all_changes,
      :changes,
      :total_files,
      :repos,
      :base_label,
      :head_label
    )

    def initialize(
      base:,
      head:,
      projects:,
      all_changes:,
      changes:,
      total_files:,
      repos:,
      base_label:,
      head_label:
    )
      @base = base
      @head = head
      @projects = projects
      @all_changes = all_changes
      @changes = changes
      @total_files = total_files
      @repos = repos
      @base_label = base_label
      @head_label = head_label
    end

    def clean?
      all_changes.empty?
    end

    def changed?
      !clean?
    end

    def report_files
      changes.map do |change|
        Report::ReportFile.new(
          repo: change.repo,
          path: change.path,
          kind: change.kind,
          old_status: change.old_status,
          new_status: change.new_status,
          old_entry: change.old_entry,
          new_entry: change.new_entry,
          old_output: change.base_output,
          new_output: change.head_output,
          input: nil,
          base_sha: change.base_sha,
          head_sha: change.head_sha,
          diff: change.diff,
          changed_lines: change.changed_lines,
          notes: change.notes
        )
      end
    end

    def report(title: "rubyfmt corpus comparison")
      Report.new(
        title: title,
        mode: "compare",
        files: report_files,
        repos: repos,
        total_files: total_files,
        base_label: base_label,
        head_label: head_label,
        notes: [],
        total_changes: all_changes.length
      )
    end
  end

  class Compare
    CACHE_FORMAT_VERSION = 1

    attr_reader(
      :manifest,
      :projects,
      :cache,
      :base_binary,
      :head_binary,
      :jobs,
      :timeout,
      :header_mode,
      :checks,
      :refresh,
      :repo_names,
      :path_glob,
      :limit
    )

    def initialize(
      manifest:,
      projects:,
      cache:,
      base_binary:,
      head_binary:,
      jobs: Etc.nprocessors,
      timeout: 10.0,
      header_mode: "default",
      checks: Snapshot::CHECK_FIELDS,
      refresh: false,
      repo_names: [],
      path_glob: nil,
      limit: 0
    )
      @manifest = manifest
      @projects = projects.sort_by(&:name)
      @cache = cache
      @base_binary = base_binary
      @head_binary = head_binary
      @jobs = jobs
      @timeout = timeout
      @header_mode = header_mode
      @checks = Array(checks).map(&:to_s).select { |check| Runner::ALLOWED_CHECKS.include?(check) }.sort
      @refresh = refresh
      @repo_names = repo_names
      @path_glob = path_glob
      @limit = limit.to_i
    end

    def run
      base_results = run_side(base_binary, "base")
      head_results = run_side(head_binary, "head")
      all_changes = build_changes(base_results, head_results)
      all_changes = filter_changes(all_changes)
      report_changes = limit.positive? ? all_changes.first(limit) : all_changes
      Comparison.new(
        base: base_results,
        head: head_results,
        projects: projects,
        all_changes: all_changes,
        changes: report_changes,
        total_files: total_files(base_results, head_results),
        repos: repo_infos,
        base_label: binary_label(base_binary, "base"),
        head_label: binary_label(head_binary, "head")
      )
    end

    private

    def run_side(binary, role)
      key = cache_key(binary, role)
      dir = File.join(cache.results_root, key)
      outputs = File.join(dir, "outputs")
      results_path = File.join(dir, "results.json")
      if !refresh && File.file?(results_path) && Dir.exist?(outputs)
        data = JSON.parse(File.read(results_path))
        return ResultSet.from_h(data, manifest: manifest, output_dir: outputs)
      end

      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(outputs)
      runner = Runner.new(
        rubyfmt: binary.path,
        manifest: manifest,
        projects: projects,
        cache: cache,
        jobs: jobs,
        timeout: timeout,
        header_mode: header_mode,
        checks: checks,
        output_dir: outputs,
        progress: $stderr.tty?,
        fetch: true
      )
      result = runner.run
      File.write(results_path, JSON.pretty_generate(result.to_h))
      result
    end

    def cache_key(binary, role)
      payload = {
        "cache_format" => CACHE_FORMAT_VERSION,
        "role" => role,
        "binary_sha256" => binary.sha256,
        "manifest_digest" => manifest.digest,
        "projects" => projects.map(&:name),
        "config" => {
          "header_mode" => header_mode,
          "checks" => checks,
          "timeout" => timeout,
          "prism_version" => Runner.prism_version,
          "ruby_version" => RUBY_VERSION
        }
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def build_changes(base_results, head_results)
      base_index = base_results.index
      head_index = head_results.index
      keys = base_index.keys | head_index.keys
      keys
        .sort
        .map do |repo, path|
          base = base_index[[repo, path]]
          head = head_index[[repo, path]]
          change = build_change(repo, path, base, head, base_results, head_results)
          change if change
        end
        .compact
    end

    def build_change(repo, path, base, head, base_results, head_results)
      candidate = FileChange.new(
        repo: repo,
        path: path,
        base: base,
        head: head,
        base_output: nil,
        head_output: nil,
        diff: nil,
        changed_lines: [],
        notes: []
      )
      return nil unless candidate.changed?

      base_output = read_output(base_results, base)
      head_output = read_output(head_results, head)
      diff = build_diff(path, base_output, head_output)
      changed_lines = if base_output || head_output
        Diff.changed_lines(base_output || "", head_output || "")
      else
        []
      end

      FileChange.new(
        repo: repo,
        path: path,
        base: base,
        head: head,
        base_output: base_output,
        head_output: head_output,
        diff: diff,
        changed_lines: changed_lines,
        notes: notes_for(base, head)
      )
    end

    def read_output(results, file)
      return nil unless file&.ok? && results.output_dir

      path = File.join(results.output_dir, file.repo, file.path)
      File.file?(path) ? File.binread(path) : nil
    end

    def build_diff(path, base_output, head_output)
      if base_output && head_output
        Diff.unified(base_output, head_output, "base/#{path}", "head/#{path}")
      elsif head_output
        Diff.unified("", head_output, "/dev/null", "head/#{path}")
      elsif base_output
        Diff.unified(base_output, "", "base/#{path}", "/dev/null")
      end
    end

    def notes_for(base, head)
      notes = []
      notes << "added" if base.nil?
      notes << "removed" if head.nil?
      if base && head
        notes << "status #{base.status} → #{head.status}" if base.status != head.status
        notes << "output changed" if base.ok? && head.ok? && base.output_sha256 != head.output_sha256
        if base.checks["idempotent"] != head.checks["idempotent"]
          notes << "idempotence #{base.checks["idempotent"].inspect} → #{head.checks["idempotent"].inspect}"
        end

        if base.checks["valid"] != head.checks["valid"]
          notes << "validity #{base.checks["valid"].inspect} → #{head.checks["valid"].inspect}"
        end
      end

      notes << "base error: #{truncate(base.error)}" if base&.error
      notes << "head error: #{truncate(head.error)}" if head&.error
      notes
    end

    def truncate(text, length = 240)
      value = text.to_s.gsub(/\s+/, " ").strip
      value.length > length ? "#{value[0, length]}..." : value
    end

    def filter_changes(changes)
      changes = changes.select { |change| repo_names.include?(change.repo) } unless repo_names.empty?
      changes = changes.select { |change| Glob.match?(path_glob, change.path) } if path_glob && !path_glob.empty?
      changes
    end

    def total_files(base_results, head_results)
      names = projects.map(&:name)
      counts = names.to_h { |name| [name, 0] }
      keys = base_results.files.map { |file| [file.repo, file.path] } |
        head_results.files.map { |file| [file.repo, file.path] }
      keys.uniq.each do |repo, _path|
        counts[repo] += 1 if counts.key?(repo)
      end

      counts
    end

    def repo_infos
      projects.map do |project|
        Report::RepoInfo.new(
          name: project.name,
          url: project.url,
          slug: project.github_slug,
          base_sha: project.sha,
          head_sha: project.sha,
          tier: project.tier
        )
      end
    end

    def binary_label(binary, role)
      "#{role}: #{binary.path} (#{binary.sha256[0, 12]})"
    end
  end
end
