require "digest"
require "json"

module Corpus
  class SnapshotError < Error
  end

  class Snapshot
    VERSION = 1
    CHECK_FIELDS = %w[idempotence validity].freeze

    SnapshotDiff = Struct.new(:repo, :path, :old_entry, :new_entry, keyword_init: true) do
      def kind
        return :added if old_entry.nil?
        return :removed if new_entry.nil?

        :changed
      end

      def changed_fields
        keys = (old_entry || {}).keys | (new_entry || {}).keys
        keys.reject { |key| (old_entry || {})[key] == (new_entry || {})[key] }.sort
      end

      def status_change
        old_status = old_entry && old_entry["status"]
        new_status = new_entry && new_entry["status"]
        old_status == new_status ? nil : [old_status, new_status]
      end
    end

    class Comparison
      attr_reader :diffs, :sha_changes, :config_changes, :old_snapshot, :new_snapshot, :project_names

      def initialize(diffs:, sha_changes:, config_changes:, old_snapshot:, new_snapshot:, project_names:)
        @diffs = diffs
        @sha_changes = sha_changes
        @config_changes = config_changes
        @old_snapshot = old_snapshot
        @new_snapshot = new_snapshot
        @project_names = project_names
      end

      def clean?
        diffs.empty? && sha_changes.empty? && config_changes.empty?
      end

      def changed?
        !clean?
      end

      def by_repo
        diffs.group_by(&:repo)
      end

      def added
        diffs.select { |diff| diff.kind == :added }
      end

      def removed
        diffs.select { |diff| diff.kind == :removed }
      end

      def changed
        diffs.select { |diff| diff.kind == :changed }
      end

      def new_errors
        diffs.select do |diff|
          new_entry = diff.new_entry || {}
          old_entry = diff.old_entry || {}
          %w[error timeout].include?(new_entry["status"]) &&
            !%w[error timeout].include?(old_entry["status"])
        end
      end

      def fixed_errors
        diffs.select do |diff|
          new_entry = diff.new_entry || {}
          old_entry = diff.old_entry || {}
          %w[error timeout].include?(old_entry["status"]) &&
            !%w[error timeout].include?(new_entry["status"])
        end
      end

      def idempotence_failures
        diffs.select do |diff|
          (diff.new_entry || {})["idempotent"] == false && (diff.old_entry || {})["idempotent"] != false
        end
      end

      def validity_failures
        diffs.select do |diff|
          (diff.new_entry || {})["valid"] == false && (diff.old_entry || {})["valid"] != false
        end
      end

      def repo_counts
        counts = {}
        project_names.each do |name|
          counts[name] = {
            total: ((new_snapshot.dig("repos", name, "files") || {}).length),
            changed: 0,
            added: 0,
            removed: 0,
            new_errors: 0,
            fixed_errors: 0,
            idempotence: 0,
            validity: 0
          }
        end

        added.each { |diff| counts[diff.repo][:added] += 1 if counts[diff.repo] }
        removed.each { |diff| counts[diff.repo][:removed] += 1 if counts[diff.repo] }
        changed.each { |diff| counts[diff.repo][:changed] += 1 if counts[diff.repo] }
        new_errors.each { |diff| counts[diff.repo][:new_errors] += 1 if counts[diff.repo] }
        fixed_errors.each { |diff| counts[diff.repo][:fixed_errors] += 1 if counts[diff.repo] }
        idempotence_failures.each { |diff| counts[diff.repo][:idempotence] += 1 if counts[diff.repo] }
        validity_failures.each { |diff| counts[diff.repo][:validity] += 1 if counts[diff.repo] }
        counts
      end
    end

    class << self
      def load(path = Corpus::DEFAULT_SNAPSHOT_PATH)
        data = JSON.parse(File.read(path))
        validate!(data)
        data
      rescue Errno::ENOENT
        raise SnapshotError, "snapshot not found: #{path}; run `ruby corpus/tool/corpus snapshot update`"
      rescue JSON::ParserError => e
        raise SnapshotError, "could not parse #{path}: #{e.message}"
      end

      def from_result_set(result_set)
        repos = {}
        result_set.projects.map(&:name).sort.each do |name|
          project = result_set.projects.find { |candidate| candidate.name == name }
          files = result_set.files_for(name)
          entries = {}
          files.each { |file| entries[file.path] = file.snapshot_entry }
          entries = sort_entries(entries)
          repos[name] = {
            "sha" => project.sha,
            "files" => entries,
            "rollup" => repo_rollup(entries)
          }
        end

        snapshot = {
          "version" => VERSION,
          "config" => snapshot_config(result_set.config),
          "rollup" => global_rollup(repos),
          "repos" => repos
        }
        snapshot
      end

      def snapshot_config(config)
        {
          "header_mode" => config["header_mode"] || "default",
          "checks" => Array(config["checks"]).map(&:to_s).select { |check| CHECK_FIELDS.include?(check) }.sort,
          "prism_version" => config["prism_version"] || (defined?(Runner) ? Runner.prism_version : nil),
          "ruby_version" => config["ruby_version"] || RUBY_VERSION
        }
      end

      def repo_rollup(entries)
        payload = entries.keys.sort.map { |path| [path, entries[path]] }
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def global_rollup(repos)
        payload = repos.keys.sort.map { |name| [name, repos[name]["sha"], repos[name]["rollup"]] }
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def finalize!(snapshot)
        repos = snapshot["repos"] || {}
        repos.each_value do |repo|
          repo["files"] = sort_entries(repo["files"] || {})
          repo["rollup"] = repo_rollup(repo["files"])
        end

        snapshot["repos"] = repos.keys.sort.to_h { |name| [name, repos[name]] }
        snapshot["rollup"] = global_rollup(snapshot["repos"])
        snapshot
      end

      def merge(old_snapshot, new_snapshot)
        merged = {
          "version" => VERSION,
          "config" => new_snapshot["config"],
          "repos" => (old_snapshot["repos"] || {}).merge(new_snapshot["repos"] || {})
        }
        finalize!(merged)
      end

      def write(path, snapshot)
        finalize!(snapshot)
        validate!(snapshot)
        File.write(path, dump(snapshot))
        snapshot
      end

      def validate!(snapshot)
        raise SnapshotError, "snapshot must be an object" unless snapshot.is_a?(Hash)
        unless snapshot["version"] == VERSION
          raise SnapshotError, "unsupported snapshot version #{snapshot["version"].inspect}; expected #{VERSION}"
        end

        config = snapshot["config"]
        unless config.is_a?(Hash) && config.key?("header_mode") && config["checks"].is_a?(Array)
          raise SnapshotError, "snapshot config is missing header_mode or checks"
        end

        repos = snapshot["repos"]
        raise SnapshotError, "snapshot repos must be an object" unless repos.is_a?(Hash)

        repos.each do |name, repo|
          raise SnapshotError, "#{name}: snapshot repo must be an object" unless repo.is_a?(Hash)
          unless repo["sha"].is_a?(String) && Project::SHA_RE.match?(repo["sha"])
            raise SnapshotError, "#{name}: snapshot repo has an invalid sha"
          end

          raise SnapshotError, "#{name}: snapshot files must be an object" unless repo["files"].is_a?(Hash)
          expected = repo_rollup(repo["files"])
          unless repo["rollup"] == expected
            raise SnapshotError, "#{name}: snapshot repo rollup does not match its files"
          end
        end

        expected = global_rollup(repos)
        unless snapshot["rollup"] == expected
          raise SnapshotError, "snapshot global rollup does not match its contents"
        end

        true
      end

      def compare(old_snapshot, new_snapshot, project_names:)
        config_changes = []
        old_config = old_snapshot["config"] || {}
        new_config = new_snapshot["config"] || {}
        %w[header_mode checks prism_version].each do |field|
          next if old_config[field] == new_config[field]

          config_changes << [field, old_config[field], new_config[field]]
        end

        diffs = []
        sha_changes = []
        project_names.sort.each do |name|
          old_repo = old_snapshot.dig("repos", name)
          new_repo = new_snapshot.dig("repos", name)
          if old_repo && new_repo && old_repo["sha"] != new_repo["sha"]
            sha_changes << [name, old_repo["sha"], new_repo["sha"]]
          end

          old_files = old_repo ? old_repo["files"] : {}
          new_files = new_repo ? new_repo["files"] : {}
          (old_files.keys | new_files.keys).sort.each do |path|
            old_entry = old_files[path]
            new_entry = new_files[path]
            next if old_entry == new_entry

            diffs << SnapshotDiff.new(repo: name, path: path, old_entry: old_entry, new_entry: new_entry)
          end
        end

        Comparison.new(
          diffs: diffs,
          sha_changes: sha_changes,
          config_changes: config_changes,
          old_snapshot: old_snapshot,
          new_snapshot: new_snapshot,
          project_names: project_names.sort
        )
      end

      def dump(snapshot)
        snapshot = finalize!(deep_copy(snapshot))
        config = snapshot["config"]
        lines = []
        lines << "{"
        lines << "  \"version\": #{VERSION},"
        config_payload = {
          "header_mode" => config["header_mode"],
          "checks" => Array(config["checks"]).sort
        }
        config_payload["prism_version"] = config["prism_version"] if config.key?("prism_version")
        config_payload["ruby_version"] = config["ruby_version"] if config.key?("ruby_version")
        lines << "  \"config\": #{JSON.generate(config_payload)},"
        lines << "  \"rollup\": #{JSON.generate(snapshot["rollup"])},"
        repos = snapshot["repos"] || {}
        if repos.empty?
          lines << "  \"repos\": {}"
        else
          lines << "  \"repos\": {"
          repo_names = repos.keys.sort
          repo_names.each_with_index do |name, index|
            repo = repos[name]
            lines << "    #{JSON.generate(name)}: {"
            lines << "      \"sha\": #{JSON.generate(repo["sha"])},"
            lines << "      \"rollup\": #{JSON.generate(repo["rollup"])},"
            files = repo["files"] || {}
            if files.empty?
              lines << "      \"files\": {}"
            else
              lines << "      \"files\": {"
              paths = files.keys.sort
              paths.each_with_index do |path, path_index|
                entry = ordered_entry(files[path])
                comma = path_index == paths.length - 1 ? "" : ","
                lines << "        #{JSON.generate(path)}: #{JSON.generate(entry)}#{comma}"
              end

              lines << "      }"
            end

            comma = index == repo_names.length - 1 ? "" : ","
            lines << "    }#{comma}"
          end

          lines << "  }"
        end

        lines << "}"
        "#{lines.join("\n")}\n"
      end

      private

      def sort_entries(entries)
        entries.keys.sort.to_h { |path| [path, ordered_entry(entries[path])] }
      end

      def ordered_entry(entry)
        return entry unless entry.is_a?(Hash)

        ordered = {}
        %w[status output_sha256 error_kind error_sha256 idempotent valid].each do |key|
          ordered[key] = entry[key] if entry.key?(key)
        end

        entry.each { |key, value| ordered[key] = value unless ordered.key?(key) }
        ordered
      end

      def deep_copy(value)
        Marshal.load(Marshal.dump(value))
      end
    end
  end
end
