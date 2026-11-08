require "digest"
require "fileutils"
require "open3"

module Corpus
  class Binary
    attr_reader :path, :sha256

    def initialize(path)
      @path = File.expand_path(path)
      raise BuildError, "rubyfmt binary not found: #{@path}" unless File.file?(@path)
      raise BuildError, "rubyfmt binary is not executable: #{@path}" unless File.executable?(@path)

      @sha256 = Digest::SHA256.file(@path).hexdigest
    end

    class << self
      def resolve(spec, repo_root:, cache:, role:, no_build: false)
        value = spec.to_s
        if value.empty? || %w[working worktree head].include?(value)
          if no_build
            path = File.join(repo_root, "target", "release", "rubyfmt-main")
            unless File.file?(path)
              raise BuildError, "#{role} binary not found at #{path}; omit --no-build or pass a binary path"
            end

            return new(path)
          end

          return new(build_working(repo_root, cache))
        end

        return new(value) if File.file?(value)

        sha = if git_ref_exists?(repo_root, value)
          git_commit(repo_root, value)
        elsif path_like?(value)
          raise BuildError, "#{role} must be a git ref or an existing binary: #{value}"
        else
          begin
            git_commit(repo_root, value)
          rescue BuildError => e
            raise(
              BuildError,
              "#{e.message}\n#{role} must be a git ref or a path to an existing rubyfmt binary. If #{value.inspect} is a remote branch, run `git fetch origin` first."
            )
          end
        end

        cached = cached_binary(cache, sha)
        return new(cached) if File.file?(cached)
        if no_build
          raise BuildError, "no cached build for #{role} #{value} (#{sha}); rerun without --no-build"
        end

        new(build_ref(repo_root, cache, sha))
      end

      def default_base_ref(repo_root)
        %w[origin/main origin/trunk trunk main].each do |ref|
          next unless git_ref_exists?(repo_root, ref)

          base = merge_base(repo_root, ref)
          return base unless base.empty?

          return ref
        end

        "HEAD"
      end

      def git_commit(repo_root, ref)
        out, err, status = Open3.capture3("git", "-C", repo_root, "rev-parse", "--verify", "#{ref}^{commit}")
        raise BuildError, "could not resolve git ref #{ref.inspect}: #{err.strip}" unless status.success?

        out.strip
      end

      def merge_base(repo_root, ref)
        out, _err, status = Open3.capture3("git", "-C", repo_root, "merge-base", "HEAD", ref)
        status.success? ? out.strip : ""
      end

      def git_ref_exists?(repo_root, ref)
        _out, _err, status = Open3.capture3(
          "git",
          "-C",
          repo_root,
          "rev-parse",
          "--verify",
          "--quiet",
          "#{ref}^{commit}"
        )
        status.success?
      end

      def cached_binary(cache, sha)
        File.join(cache.builds_root, "#{sha}-#{RUBY_PLATFORM}", "rubyfmt-main")
      end

      def build_working(repo_root, cache)
        output = File.join(repo_root, "target", "release", "rubyfmt-main")
        return output if File.file?(output) && !stale?(repo_root, output)

        $stderr.puts("Building rubyfmt from the working tree...") if $stderr.tty?
        run_cargo(repo_root)
        raise BuildError, "cargo build did not produce #{output}" unless File.file?(output)

        output
      end

      def build_ref(repo_root, cache, sha)
        cached = cached_binary(cache, sha)
        return cached if File.file?(cached)

        @mutex ||= Mutex.new
        @mutex.synchronize do
          return cached if File.file?(cached)

          worktree = File.join(cache.worktrees_root, "#{sha}-#{Process.pid}")
          target = File.join(cache.targets_root, sha)
          FileUtils.mkdir_p(File.dirname(worktree))
          git_quiet(repo_root, "worktree", "prune")
          FileUtils.rm_rf(worktree)
          git!(repo_root, "worktree", "add", "--detach", "--force", worktree, sha)
          begin
            $stderr.puts("Building rubyfmt at #{sha[0, 12]}...") if $stderr.tty?
            run_cargo(worktree, target: target)
            built = File.join(target, "release", "rubyfmt-main")
            raise BuildError, "cargo build at #{sha} did not produce #{built}" unless File.file?(built)

            FileUtils.mkdir_p(File.dirname(cached))
            FileUtils.cp(built, cached)
            FileUtils.chmod(0o755, cached)
            cached
          ensure
            git_quiet(repo_root, "worktree", "remove", "--force", worktree)
            FileUtils.rm_rf(worktree)
            FileUtils.rm_rf(target)
          end
        end
      end

      def run_cargo(dir, target: nil)
        env = target ? {"CARGO_TARGET_DIR" => target} : {}
        command = ["cargo", "build", "--release", "--locked"]
        status = nil
        Open3.popen2e(env, *command, chdir: dir) do |stdin, output, wait|
          stdin.close
          output.each { |line| $stderr.print(line) }
          status = wait.value
        end

        raise BuildError, "cargo build failed in #{dir}" unless status&.success?
      end

      private

      def path_like?(value)
        return true if value.start_with?("/", "~", ".")
        return true if value.match?(%r{\A[A-Za-z]:[\\/]})

        directory = File.dirname(value)
        directory != "." && File.directory?(directory)
      end

      def stale?(repo_root, output)
        output_mtime = File.mtime(output)
        tracked = %w[Cargo.toml Cargo.lock src librubyfmt]
        tracked.any? do |entry|
          path = File.join(repo_root, entry)
          next false unless File.exist?(path)

          if File.directory?(path)
            Dir.glob(File.join(path, "**", "*")).any? { |file| File.file?(file) && File.mtime(file) > output_mtime }
          else
            File.mtime(path) > output_mtime
          end
        end
      end

      def git!(repo_root, *args)
        out, err, status = Open3.capture3("git", "-C", repo_root, *args)
        return out if status.success?

        raise BuildError, "git #{args.join(" ")} failed in #{repo_root}:\n#{err.strip}"
      end

      def git_quiet(repo_root, *args)
        Open3.capture3("git", "-C", repo_root, *args)
      rescue StandardError
        nil
      end
    end
  end
end
