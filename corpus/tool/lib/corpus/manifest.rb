require "digest"
require "open3"
require "yaml"

module Corpus
  class Error < StandardError
  end

  class ManifestError < Error
  end

  class CacheError < Error
  end

  class RunnerError < Error
  end

  class BuildError < Error
  end

  module Defaults
    INCLUDE = [
      "**/*.rb",
      "**/*.rake",
      "**/*.gemspec",
      "**/Rakefile",
      "**/Gemfile",
      "**/config.ru"
    ].freeze

    EXCLUDE = [
      "**/.git/**",
      "**/vendor/**",
      "**/node_modules/**",
      "**/tmp/**",
      "**/coverage/**",
      "**/fixtures/**"
    ].freeze
  end

  class Project
    KINDS = %w[app gem framework tool].freeze
    TIERS = %w[fast full].freeze
    SHA_RE = /\A[0-9a-f]{40}\z/
    NAME_RE = /\A[a-z0-9][a-z0-9._-]*\z/

    attr_reader :name, :url, :sha, :kind, :tier, :include, :exclude

    def initialize(hash)
      @name = hash["name"]
      @url = hash["url"]
      @sha = hash["sha"]
      @kind = hash["kind"]
      @tier = hash["tier"] || "full"
      @include = Array(hash.key?("include") ? hash["include"] : Defaults::INCLUDE)
      @exclude = Array(hash.key?("exclude") ? hash["exclude"] : Defaults::EXCLUDE)
    end

    def to_h
      {
        "name" => name,
        "url" => url,
        "sha" => sha,
        "kind" => kind,
        "tier" => tier,
        "include" => include,
        "exclude" => exclude
      }
    end

    def fast?
      tier == "fast"
    end

    def github_slug
      match = url.match(%r{\Agit@github\.com:(.+?)(?:\.git)?\z}) ||
        url.match(%r{\Ahttps?://github\.com/(.+?)(?:\.git)?\z})
      match && match[1]
    end

    def validate
      errors = []
      errors << "name must match #{NAME_RE.inspect}" unless name.is_a?(String) && NAME_RE.match?(name)
      unless url.is_a?(String) && url.match?(%r{\A(?:(?:https?|file)://|git@)})
        errors << "url must be an https://, file://, or git@ URL"
      end

      errors << "sha must be a full 40-character lowercase hex SHA" unless sha.is_a?(String) && SHA_RE.match?(sha)
      errors << "kind must be one of: #{KINDS.join(", ")}" unless KINDS.include?(kind)
      errors << "tier must be one of: #{TIERS.join(", ")}" unless TIERS.include?(tier)
      unless include.is_a?(Array) && !include.empty? && include.all? { |glob| glob.is_a?(String) && !glob.empty? }
        errors << "include must be a non-empty array of glob strings"
      end

      unless exclude.is_a?(Array) && exclude.all? { |glob| glob.is_a?(String) && !glob.empty? }
        errors << "exclude must be an array of glob strings"
      end

      (include + exclude).each do |glob|
        next unless glob.is_a?(String)

        errors << "glob must be relative: #{glob.inspect}" if glob.start_with?("/")
        errors << "glob must not contain NUL: #{glob.inspect}" if glob.include?("\0")
        begin
          Glob.regex(glob)
        rescue RegexpError => e
          errors << "invalid glob #{glob.inspect}: #{e.message}"
        end
      end

      errors
    end
  end

  class Manifest
    attr_reader :path, :projects

    def initialize(path = Corpus::DEFAULT_MANIFEST_PATH)
      @path = File.expand_path(path)
      @projects = load_projects
    end

    def validate!
      errors = []
      errors << "manifest is empty" if projects.empty?
      seen = {}
      projects.each_with_index do |project, index|
        label = project.name.is_a?(String) && !project.name.empty? ? project.name : "##{index}"
        errors << "#{label}: duplicate project name" if seen[project.name]
        seen[project.name] = true
        project.validate.each { |error| errors << "#{label}: #{error}" }
      end

      raise ManifestError, errors.join("\n") unless errors.empty?

      true
    end

    def [](name)
      projects.find { |project| project.name == name }
    end

    def names
      projects.map(&:name)
    end

    def select(names: nil, tier: nil)
      selected = projects
      if names && !names.empty?
        unknown = names - self.names()
        raise ManifestError, "unknown project(s): #{unknown.join(", ")}" unless unknown.empty?

        selected = selected.select { |project| names.include?(project.name) }
      end

      if tier
        valid = Project::TIERS + ["all"]
        unless valid.include?(tier)
          raise ManifestError, "unknown tier #{tier.inspect}; expected one of: #{valid.join(", ")}"
        end

        selected = selected.select { |project| project.tier == "fast" } if tier == "fast"
      end

      raise ManifestError, "no projects selected" if selected.empty?

      selected.sort_by(&:name)
    end

    def digest
      Digest::SHA256.file(path).hexdigest
    end

    def bump(name, ref = nil)
      project = self[name]
      raise ManifestError, "unknown project: #{name}" unless project

      new_sha = resolve_sha(project.url, ref || "HEAD")
      old_sha = project.sha
      return [old_sha, new_sha] if old_sha == new_sha

      update_sha_in_file(name, new_sha)
      @projects = load_projects
      validate!
      [old_sha, new_sha]
    end

    def write
      header = [
        "# rubyfmt corpus manifest.",
        "# Each project is pinned to a full commit SHA.",
        "# Bump a SHA with: ruby corpus/tool/corpus bump <name> [sha-or-ref]",
        "# Validate with:   ruby corpus/tool/corpus validate",
        ""
      ].join("\n")
      body = YAML.dump(projects.map(&:to_h), line_width: -1)
      File.write(path, "#{header}#{body}")
    end

    def resolve_sha(url, ref)
      return ref if ref.is_a?(String) && Project::SHA_RE.match?(ref)
      if ref.is_a?(String) && ref.match?(/\A[0-9a-f]{7,39}\z/)
        raise ManifestError, "short SHAs are not supported; pass the full 40-character SHA or a git ref"
      end

      env = {
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_ASKPASS" => "/bin/true",
        "LC_ALL" => "C"
      }
      out, err, status = Open3.capture3(env, "git", "ls-remote", url, ref)
      unless status.success?
        raise ManifestError, "could not resolve #{ref.inspect} from #{url}: #{err.strip}"
      end

      line = out.lines.find { |candidate| candidate.split(/\s+/).last == ref } || out.lines.first
      sha = line&.split&.first
      unless sha && Project::SHA_RE.match?(sha)
        raise ManifestError, "could not resolve #{ref.inspect} from #{url} to a full commit SHA"
      end

      sha
    end

    private

    def update_sha_in_file(name, new_sha)
      lines = File.readlines(path)
      in_project = false
      changed = false
      lines.each_with_index do |line, index|
        if (match = line.match(/^-\s+name:\s*(.+?)\s*$/))
          in_project = match[1] == name
        elsif in_project && (match = line.match(/^(\s+sha:\s*)\S+/))
          lines[index] = "#{match[1]}#{new_sha}\n"
          changed = true
          in_project = false
        end
      end

      raise ManifestError, "could not find sha line for project #{name.inspect} in #{path}" unless changed

      File.write(path, lines.join)
    end

    def load_projects
      raw = YAML.safe_load(File.read(path), aliases: true)
      unless raw.is_a?(Array)
        raise ManifestError, "#{path}: expected a YAML list of projects"
      end

      raw.each_with_index.map do |entry, index|
        raise ManifestError, "#{path}: project ##{index} must be a mapping" unless entry.is_a?(Hash)

        Project.new(entry)
      end

    rescue Errno::ENOENT
      raise ManifestError, "manifest not found: #{path}"
    rescue Psych::SyntaxError => e
      raise ManifestError, "could not parse #{path}: #{e.message}"
    end
  end
end
