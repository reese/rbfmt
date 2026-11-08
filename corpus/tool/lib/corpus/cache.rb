require "fileutils"
require "open3"
require "etc"

module Corpus
  class Cache
    attr_reader :root

    def initialize(root: Corpus::DEFAULT_CACHE_ROOT)
      @root = File.expand_path(root)
    end

    def repos_root
      File.join(root, "repos")
    end

    def results_root
      File.join(root, "results")
    end

    def builds_root
      File.join(root, "builds")
    end

    def targets_root
      File.join(root, "targets")
    end

    def worktrees_root
      File.join(root, "worktrees")
    end

    def workdir
      dir = File.join(root, "work")
      FileUtils.mkdir_p(dir)
      dir
    end

    def repo_dir(project)
      File.join(repos_root, project.name, project.sha)
    end

    def fetch(project)
      dir = repo_dir(project)
      return dir if valid?(project, dir)

      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(File.dirname(dir))
      begin
        git("init", "--quiet", dir)
        git("remote", "add", "origin", project.url, chdir: dir)
        begin
          git("fetch", "--depth", "1", "--no-tags", "--quiet", "origin", project.sha, chdir: dir)
        rescue Error
          git("fetch", "--no-tags", "--quiet", "origin", project.sha, chdir: dir)
        end

        git(
          "-c",
          "advice.detachedHead=false",
          "-c",
          "core.autocrlf=false",
          "-c",
          "core.eol=lf",
          "checkout",
          "--quiet",
          "--detach",
          "FETCH_HEAD",
          chdir: dir
        )
        actual = git("rev-parse", "HEAD", chdir: dir).strip
        unless actual == project.sha
          raise CacheError, "#{project.name}: expected #{project.sha}, got #{actual}"
        end

        dir
      rescue Error
        FileUtils.rm_rf(dir)
        raise
      end
    end

    def valid?(project, dir = repo_dir(project))
      return false unless File.directory?(File.join(dir, ".git"))

      git("rev-parse", "HEAD", chdir: dir).strip == project.sha
    rescue Error
      false
    end

    def fetch_all(projects, jobs: Etc.nprocessors)
      jobs = [[jobs.to_i, 1].max, projects.length].min
      queue = Queue.new
      projects.each { |project| queue << project }
      errors = []
      mutex = Mutex.new

      workers = Array.new(jobs) do
        Thread.new do
          loop do
            project = begin
              queue.pop(true)
            rescue ThreadError
              break
            end

            begin
              dir = fetch(project)
              mutex.synchronize { yield(project, dir) if block_given? }
            rescue StandardError => e
              mutex.synchronize { errors << [project, e] }
            end
          end
        end
      end

      workers.each(&:join)

      return if errors.empty?

      message = errors.map { |project, error| "#{project.name}: #{error.message}" }.join("\n")
      raise CacheError, "failed to fetch corpus:\n#{message}"
    end

    def git(*args, chdir: nil)
      env = {
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_ASKPASS" => "/bin/true",
        "LC_ALL" => "C"
      }
      command = ["git"]
      command += ["-C", chdir] if chdir
      command += args

      out, err, status = Open3.capture3(env, *command)
      return out if status.success?

      raise CacheError, "#{command.join(" ")} failed#{chdir ? " in #{chdir}" : ""}:\n#{err.strip}"
    end
  end
end
