require "digest"
require "etc"
require "fileutils"
require "json"
require "open3"

module Corpus
  class FileResult
    attr_reader(
      :repo,
      :path,
      :status,
      :output_sha256,
      :input_sha256,
      :error_sha256,
      :error,
      :error_kind,
      :exit_code,
      :duration_ms,
      :checks
    )

    def initialize(
      repo:,
      path:,
      status:,
      output_sha256: nil,
      input_sha256: nil,
      error_sha256: nil,
      error: nil,
      error_kind: nil,
      exit_code: nil,
      duration_ms: 0,
      checks: {}
    )
      @repo = repo
      @path = path
      @status = status
      @output_sha256 = output_sha256
      @input_sha256 = input_sha256
      @error_sha256 = error_sha256
      @error = error
      @error_kind = error_kind
      @exit_code = exit_code
      @duration_ms = duration_ms
      @checks = checks || {}
    end

    def ok?
      status == "ok"
    end

    def failed?
      %w[error timeout].include?(status)
    end

    def snapshot_entry
      entry = {"status" => status}
      case status
      when "ok"
        entry["output_sha256"] = output_sha256
      when "error", "timeout"
        entry["error_kind"] = error_kind
        entry["error_sha256"] = error_sha256
      end

      entry["idempotent"] = false if checks["idempotent"] == false
      entry["valid"] = false if checks["valid"] == false
      entry
    end

    def to_h
      hash = {
        "path" => path,
        "status" => status,
        "exit_code" => exit_code,
        "duration_ms" => duration_ms
      }
      hash["input_sha256"] = input_sha256 if input_sha256
      hash["output_sha256"] = output_sha256 if output_sha256
      hash["error_kind"] = error_kind if error_kind
      hash["error_sha256"] = error_sha256 if error_sha256
      hash["error"] = error if error
      hash["checks"] = checks unless checks.empty?
      hash
    end

    def self.from_h(repo, hash)
      new(
        repo: repo,
        path: hash["path"],
        status: hash["status"],
        output_sha256: hash["output_sha256"],
        input_sha256: hash["input_sha256"],
        error_sha256: hash["error_sha256"],
        error: hash["error"],
        error_kind: hash["error_kind"],
        exit_code: hash["exit_code"],
        duration_ms: hash["duration_ms"] || 0,
        checks: hash["checks"] || {}
      )
    end
  end

  class ResultSet
    attr_reader :manifest, :projects, :rubyfmt, :config, :files, :duration_ms, :output_dir

    def initialize(manifest:, projects:, rubyfmt:, config:, files:, duration_ms:, output_dir: nil)
      @manifest = manifest
      @projects = projects.sort_by(&:name)
      @rubyfmt = rubyfmt
      @config = config
      @files = files.sort_by { |file| [file.repo, file.path] }
      @duration_ms = duration_ms
      @output_dir = output_dir
    end

    def rollup
      Snapshot.from_result_set(self)["rollup"]
    end

    def files_for(repo)
      grouped_files[repo] || []
    end

    def find(repo, path)
      index[[repo, path]]
    end

    def to_h
      {
        "version" => 1,
        "rubyfmt" => rubyfmt,
        "config" => config,
        "corpus" => {
          "path" => manifest.path,
          "digest" => manifest.digest
        },
        "rollup" => rollup,
        "duration_ms" => duration_ms,
        "projects" => projects.map do |project|
          {
            "name" => project.name,
            "url" => project.url,
            "sha" => project.sha,
            "kind" => project.kind,
            "tier" => project.tier,
            "files" => files_for(project.name).map(&:to_h)
          }
        end
      }
    end

    def index
      @index ||= files.to_h { |file| [[file.repo, file.path], file] }
    end

    def grouped_files
      @grouped_files ||= files.group_by(&:repo)
    end

    def self.from_h(data, manifest:, output_dir: nil)
      projects = data.fetch("projects").map do |project_data|
        project = manifest[project_data["name"]]
        raise RunnerError, "results contain unknown project #{project_data["name"].inspect}" unless project

        project
      end

      files = data.fetch("projects").flat_map do |project_data|
        project_data.fetch("files").map { |file| FileResult.from_h(project_data["name"], file) }
      end

      new(
        manifest: manifest,
        projects: projects,
        rubyfmt: data["rubyfmt"] || {},
        config: data["config"] || {},
        files: files,
        duration_ms: data["duration_ms"] || 0,
        output_dir: output_dir
      )
    end
  end

  class Runner
    HEADER_MODES = %w[default opt-in opt-out].freeze
    ALLOWED_CHECKS = %w[idempotence validity ast].freeze
    def self.prism_version
      require "prism"

      Prism::VERSION
    rescue LoadError
      nil
    end

    attr_reader(
      :rubyfmt,
      :manifest,
      :projects,
      :cache,
      :jobs,
      :timeout,
      :header_mode,
      :checks,
      :output_dir,
      :progress,
      :fetch_jobs,
      :known_entries
    )

    def initialize(
      rubyfmt:,
      manifest:,
      projects:,
      cache:,
      jobs: Etc.nprocessors,
      timeout: 10.0,
      header_mode: "default",
      checks: Snapshot::CHECK_FIELDS,
      output_dir: nil,
      progress: $stderr.tty?,
      fetch: true,
      fetch_jobs: Etc.nprocessors,
      known_entries: nil
    )
      @rubyfmt = File.expand_path(rubyfmt)
      @manifest = manifest
      @projects = projects.sort_by(&:name)
      @cache = cache
      @jobs = [jobs.to_i, 1].max
      @timeout = Float(timeout)
      @header_mode = header_mode.to_s
      @checks = Array(checks).map(&:to_s).select { |check| ALLOWED_CHECKS.include?(check) }.sort
      @output_dir = output_dir && File.expand_path(output_dir)
      @progress = progress
      @fetch = fetch
      @fetch_jobs = fetch_jobs
      @known_entries = known_entries
      validate!
    end

    def self.select_files(root, project)
      files = Dir.glob(project.include, base: root, flags: File::FNM_DOTMATCH).select do |relative|
        !relative.start_with?(".git/") && File.file?(File.join(root, relative))
      end

      files = files.uniq
      files.reject! { |relative| Glob.any_match?(project.exclude, relative) }
      files.sort
    end

    def run
      started = clock
      fetch_corpus if @fetch
      work = build_work_list
      results = run_per_file(work)
      duration_ms = ((clock - started) * 1000).round
      ResultSet.new(
        manifest: manifest,
        projects: projects,
        rubyfmt: rubyfmt_info,
        config: {
          "header_mode" => header_mode,
          "checks" => checks,
          "prism_version" => self.class.prism_version,
          "ruby_version" => RUBY_VERSION
        },
        files: results,
        duration_ms: duration_ms,
        output_dir: output_dir
      )
    end

    private

    def run_per_file(work)
      results = Array.new(work.length)
      queue = Queue.new
      work.each_index { |index| queue << index }
      mutex = Mutex.new
      completed = 0
      total = work.length

      workers = Array.new([jobs, [total, 1].max].min) do
        Thread.new do
          loop do
            index = begin
              queue.pop(true)
            rescue ThreadError
              break
            end

            project, root, relative = work[index]
            begin
              results[index] = format_file(project, root, relative)
            rescue StandardError => e
              results[index] = runner_error_result(project, relative, e)
            end

            mutex.synchronize do
              completed += 1
              report_progress(completed, total)
            end
          end
        end
      end

      workers.each(&:join)
      results
    end

    def static_checks(input, output)
      results = {}
      if checks.include?("validity")
        input_valid = valid_ruby?(input)
        output_valid = valid_ruby?(output)
        results["valid"] = output_valid if input_valid == true && !output_valid.nil?
      end

      if checks.include?("ast")
        equal = ast_equal?(input, output)
        results["ast_equal"] = equal unless equal.nil?
      end

      results
    end

    def report_progress(completed, total)
      return unless progress
      return unless completed == total || (completed % 100).zero?

      $stderr.print("\rformatted #{completed}/#{total} files")
      $stderr.print("\n") if completed == total
    end

    def runner_error_result(project, relative, error)
      message = "runner error: #{error.class}: #{error.message}"
      FileResult.new(
        repo: project.name,
        path: relative,
        status: "error",
        error_kind: "runner_error",
        error: message,
        error_sha256: Digest::SHA256.hexdigest(message),
        duration_ms: 0,
        checks: {}
      )
    end

    def validate!
      raise RunnerError, "rubyfmt binary not found: #{rubyfmt}" unless File.file?(rubyfmt)
      raise RunnerError, "rubyfmt is not executable: #{rubyfmt}" unless File.executable?(rubyfmt)
      raise RunnerError, "unknown header mode #{header_mode.inspect}" unless HEADER_MODES.include?(header_mode)
      raise RunnerError, "timeout must be positive" unless timeout.positive?

      unknown_checks = checks - ALLOWED_CHECKS
      raise RunnerError, "unknown checks: #{unknown_checks.join(", ")}" unless unknown_checks.empty?
    end

    def fetch_corpus
      cache.fetch_all(projects, jobs: fetch_jobs) do |project, _dir|
        $stderr.puts("fetched #{project.name}@#{project.sha}") if progress
      end
    end

    def build_work_list
      work = []
      projects.each do |project|
        root = cache.fetch(project)
        self.class.select_files(root, project).each do |relative|
          work << [project, root, relative]
        end
      end

      work.sort_by! { |project, _root, relative| [project.name, relative] }
      work
    end

    def format_file(project, root, relative)
      absolute = File.join(root, relative)
      input = File.binread(absolute)
      input_sha256 = Digest::SHA256.hexdigest(input)

      if header_skipped?(input)
        return FileResult.new(
          repo: project.name,
          path: relative,
          status: "skipped",
          input_sha256: input_sha256,
          duration_ms: 0,
          checks: {}
        )
      end

      started = clock
      output, stderr, status, timed_out = run_rubyfmt(input)
      duration_ms = ((clock - started) * 1000).round

      if timed_out
        message = "rubyfmt timed out after #{timeout}s"
        return FileResult.new(
          repo: project.name,
          path: relative,
          status: "timeout",
          input_sha256: input_sha256,
          error: message,
          error_kind: "timeout",
          error_sha256: Digest::SHA256.hexdigest(message),
          duration_ms: duration_ms,
          checks: {}
        )
      end

      unless status&.success?
        message = normalize_error(stderr, root)
        message = "rubyfmt exited with status #{exit_code(status)}" if message.empty?
        kind = error_kind(message)
        return FileResult.new(
          repo: project.name,
          path: relative,
          status: "error",
          input_sha256: input_sha256,
          error: message,
          error_kind: kind,
          error_sha256: Digest::SHA256.hexdigest(message),
          exit_code: exit_code(status),
          duration_ms: duration_ms,
          checks: {}
        )
      end

      output_sha256 = Digest::SHA256.hexdigest(output)
      known = known_entries && known_entries[[project.name, relative]]
      check_results = if known_checks_reusable?(known, output_sha256)
        known_checks(known)
      else
        run_checks(input, output)
      end

      write_output(project, relative, output)
      FileResult.new(
        repo: project.name,
        path: relative,
        status: "ok",
        input_sha256: input_sha256,
        output_sha256: output_sha256,
        exit_code: 0,
        duration_ms: duration_ms,
        checks: check_results
      )
    rescue SystemCallError => e
      message = "runner IO error: #{e.message}"
      FileResult.new(
        repo: project.name,
        path: relative,
        status: "error",
        error: message,
        error_kind: "io_error",
        error_sha256: Digest::SHA256.hexdigest(message),
        duration_ms: 0,
        checks: {}
      )
    end

    def known_checks_reusable?(known, output_sha256)
      known && known["status"] == "ok" && known["output_sha256"] == output_sha256
    end

    def known_checks(known)
      results = {}
      results["idempotent"] = false if checks.include?("idempotence") && known["idempotent"] == false
      results["valid"] = false if checks.include?("validity") && known["valid"] == false
      results
    end

    def run_checks(input, output)
      results = static_checks(input, output)
      if checks.include?("idempotence")
        second, _stderr, status, timed_out = run_rubyfmt(output)
        results["idempotent"] = !timed_out && status&.success? && second == output
      end

      results
    end

    def run_rubyfmt(input)
      command = [rubyfmt]
      command << "--header-opt-in" if header_mode == "opt-in"
      command << "--header-opt-out" if header_mode == "opt-out"
      run_process(command, input, timeout: timeout)
    end

    def run_process(command, input, timeout:)
      stdout_r = nil
      stderr_r = nil
      stdin_w = nil
      wait_thread = nil
      out_thread = nil
      err_thread = nil
      timed_out = false
      env = {
        "LC_ALL" => "C.UTF-8",
        "LANG" => "C.UTF-8",
        "TZ" => "UTC",
        "RUST_BACKTRACE" => "0",
        "RUST_LIB_BACKTRACE" => "0",
        "RUST_LOG" => nil,
        "NO_COLOR" => "1",
        "TERM" => "dumb",
        "RUBYOPT" => nil,
        "RUBYLIB" => nil
      }

      stdin_w, stdout_r, stderr_r, wait_thread = Open3.popen3(
        env,
        *command,
        chdir: cache.workdir,
        pgroup: true
      )
      writer = Thread.new do
        begin
          stdin_w.binmode
          stdin_w.write(input)
        rescue Errno::EPIPE, IOError
        ensure
          stdin_w.close unless stdin_w.closed?
        end
      end

      out_thread = Thread.new do
        stdout_r.binmode
        stdout_r.read
      end

      err_thread = Thread.new do
        stderr_r.binmode
        stderr_r.read
      end

      deadline = clock + timeout
      status = nil
      loop do
        if wait_thread.join(0.02)
          status = wait_thread.value
          break
        end

        next unless clock >= deadline

        timed_out = true
        kill_process_group(wait_thread.pid)
        wait_thread.join(2)
        status = wait_thread.value if wait_thread.join(0)
        break
      end

      writer.join(2)
      writer.kill if writer.alive?
      out_thread.join(2)
      err_thread.join(2)
      [out_thread.value || "", err_thread.value || "", status, timed_out]
    ensure
      [stdin_w, stdout_r, stderr_r].compact.each do |io|
        io.close unless io.closed?
      rescue IOError
      end
    end

    def kill_process_group(pid)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH, Errno::EPERM
      end
    end

    def exit_code(status)
      return nil unless status

      status.exitstatus || (128 + status.termsig.to_i)
    end

    def header_skipped?(input)
      return false if header_mode == "default"

      slice = input.byteslice(0, 500).to_s.dup.force_encoding(Encoding::UTF_8).scrub
      value = parse_magic_comment(slice)
      return true if header_mode == "opt-in" && value != "true"
      return true if header_mode == "opt-out" && value == "false"

      false
    end

    def parse_magic_comment(slice)
      slice.lines.each do |line|
        next unless line.start_with?("#")

        rest = line[1..].to_s.lstrip
        next unless rest.start_with?("rubyfmt:")

        value = rest.delete_prefix("rubyfmt:").strip
        return value if %w[true false].include?(value)
      end

      nil
    end

    def normalize_error(stderr, root, extra_paths: [])
      text = stderr.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      text = text.gsub(/\e\[[0-9;]*[A-Za-z]/, "")
      text = text.gsub("\r\n", "\n")
      [cache.root, root, cache.workdir, Dir.pwd, *extra_paths].compact.uniq.sort_by { |value| -value.length }.each do |
          value
        |
        text = text.gsub(value, "<path>")
      end

      text = text.gsub(
        %r{\b(?:[A-Za-z]:)?[^\s:]*[\\/](?:librubyfmt|src)[\\/][^\s:]+\.rs(?::\d+:\d+)?},
        "<rubyfmt-source>"
      )
      text.strip
    end

    def error_kind(message)
      return "timeout" if message.include?("timed out")
      return "panic" if message.include?("panicked at")
      return "syntax_error" if message.include?("syntax error")

      "error"
    end

    def write_output(project, relative, output)
      return unless output_dir

      destination = File.join(output_dir, project.name, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      File.binwrite(destination, output)
    end

    def rubyfmt_info
      @rubyfmt_info ||= begin
        version, = Open3.capture3(
          {
            "LC_ALL" => "C.UTF-8",
            "LANG" => "C.UTF-8",
            "RUST_BACKTRACE" => "0",
            "RUST_LOG" => nil
          },
          rubyfmt,
          "--version",
          chdir: cache.workdir
        )
        {
          "path" => rubyfmt,
          "sha256" => Digest::SHA256.file(rubyfmt).hexdigest,
          "version" => version.lines.first&.strip || "unknown"
        }
      rescue StandardError
        {
          "path" => rubyfmt,
          "sha256" => Digest::SHA256.file(rubyfmt).hexdigest,
          "version" => "unknown"
        }
      end
    end

    def prism_available?
      return @prism_available unless @prism_available.nil?

      @prism_available = begin
        require "prism"

        true
      rescue LoadError
        false
      end
    end

    def valid_ruby?(bytes)
      return nil unless prism_available?

      Prism.parse(bytes).errors.empty?
    rescue StandardError
      false
    end

    def ast_equal?(input, output)
      return nil unless prism_available?

      left = normalized_ast(input)
      right = normalized_ast(output)
      return nil unless left && right

      left == right
    end

    def normalized_ast(bytes)
      result = Prism.parse(bytes)
      return nil unless result.errors.empty?

      normalize_node(result.value)
    rescue StandardError
      nil
    end

    def normalize_node(value)
      case value
      when Prism::Node
        hash = value.deconstruct_keys(nil)
        hash.each_with_object({}) do |(key, child), result|
          next if key == :node_id || key == :location || key.to_s.end_with?("_loc")

          result[key] = normalize_node(child)
        end

      when Prism::Location
        nil
      when Array
        value.map { |child| normalize_node(child) }
      when Hash
        value.to_h { |key, child| [key, normalize_node(child)] }
      else
        value
      end
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
