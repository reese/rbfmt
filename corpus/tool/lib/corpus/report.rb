require "cgi/escape"
require "digest"
require "fileutils"

module Corpus
  class Report
    ReportFile = Struct.new(
      :repo,
      :path,
      :kind,
      :old_status,
      :new_status,
      :old_entry,
      :new_entry,
      :old_output,
      :new_output,
      :input,
      :base_sha,
      :head_sha,
      :diff,
      :changed_lines,
      :notes,
      keyword_init: true
    )

    RepoInfo = Struct.new(:name, :url, :slug, :base_sha, :head_sha, :tier, keyword_init: true)

    TOKEN_PATTERN = /
      (?<comment>\#[^\n]*) |
      (?<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`) |
      (?<symbol>:[A-Za-z_]\w*[!?=]?) |
      (?<number>\b\d[\d_]*(?:\.\d+)?\b) |
      (?<keyword>\b(?:BEGIN|END|alias|and|begin|break|case|class|def|defined\?|do|else|elsif|end|ensure|false|for|if|in|module|next|nil|not|or|redo|rescue|retry|return|self|super|then|true|undef|unless|until|when|while|yield)\b) |
      (?<constant>\b[A-Z]\w*\b)
    /x

    attr_reader(
      :title,
      :mode,
      :files,
      :repos,
      :total_files,
      :update_command,
      :base_label,
      :head_label,
      :notes,
      :total_changes
    )

    def initialize(
      title:,
      mode:,
      files:,
      repos:,
      total_files:,
      update_command: nil,
      base_label: nil,
      head_label: nil,
      notes: [],
      total_changes: nil,
      show_update: nil
    )
      @title = title
      @mode = mode
      @files = files
      @repos = repos
      @total_files = total_files
      @update_command = update_command
      @base_label = base_label
      @head_label = head_label
      @notes = notes
      @total_changes = total_changes || files.length
      @show_update = show_update.nil? ? !files.empty? : show_update
    end

    def write(dir)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "summary.md"), summary)
      File.write(File.join(dir, "summary.txt"), summary)
      File.write(File.join(dir, "report.html"), html)
      File.write(File.join(dir, "diffs.txt"), diffs_text)
      summary
    end

    def clean?
      files.empty?
    end

    def summary
      @summary ||= begin
        lines = []
        lines << "# #{title}"
        lines << ""
        lines << "- Mode: `#{mode}`"
        lines << "- Base: `#{base_label}`" if base_label
        lines << "- Head: `#{head_label}`" if head_label
        lines << "- Result: #{result_text}"
        lines << "- Files in corpus: #{total_files.values.sum}"
        lines << ""
        notes.each { |note| lines << "> #{note}" }
        lines << "" unless notes.empty?
        lines << "| Repo | Files | Changed | Added | Removed | New errors | Fixed errors | Idempotence | Validity |"
        lines << "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
        repo_rows.each do |row|
          lines <<
            "| #{row[:repo]} | #{row[:total]} | #{row[:changed]} | #{row[:added]} | #{row[:removed]} | #{row[:new_errors]} | #{row[:fixed_errors]} | #{row[:idempotence]} | #{row[:validity]} |"
        end

        lines << ""
        lines << "## Top changed files"
        lines << ""
        if files.empty?
          lines << "No formatting changes."
        else
          top_files.each do |file|
            lines <<
              "- `#{file.repo}/#{file.path}` (#{changed_size(file)} changed line#{changed_size(file) == 1 ? "" : "s"})"
          end
        end

        if update_command && !update_command.empty? && @show_update
          lines << ""
          lines << "## Update the snapshot"
          lines << ""
          lines << "If these changes are intentional, update the committed snapshot:"
          lines << ""
          lines << "```sh"
          lines << update_command
          lines << "```"
        end

        lines.join("\n")
      end
    end

    def html
      @html ||= begin
        clusters = clusters_for(files)
        cluster_html = clusters.map { |cluster| render_cluster(cluster) }.join("\n")
        repo_options = repos.map { |repo| "<option value=\"#{h(repo.name)}\">#{h(repo.name)}</option>" }.join
        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{h(title)}</title>
          <style>
          :root { color-scheme: light; --border: #d0d7de; --muted: #57606a; --bg: #ffffff; --add: #e6ffec; --del: #ffebe9; --hunk: #ddf4ff; --accent: #0969da; }
          * { box-sizing: border-box; }
          body { margin: 0 auto; max-width: 1400px; padding: 24px; font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #1f2328; background: var(--bg); }
          h1 { margin-top: 0; }
          .muted { color: var(--muted); }
          .badge { display: inline-block; margin-right: 6px; padding: 1px 6px; border: 1px solid var(--border); border-radius: 999px; font-size: 12px; background: #f6f8fa; }
          .badge.err { color: #cf222e; border-color: #ff8182; background: #ffebe9; }
          .badge.ok { color: #116329; border-color: #4ac26b; background: #dafbe1; }
          .controls { display: flex; flex-wrap: wrap; gap: 8px; margin: 16px 0; }
          .controls input[type="search"] { min-width: 320px; }
          .controls input, .controls select { padding: 6px 8px; border: 1px solid var(--border); border-radius: 6px; background: #fff; }
          table { border-collapse: collapse; width: 100%; margin: 12px 0 24px; }
          th, td { border: 1px solid var(--border); padding: 6px 8px; text-align: right; }
          th:first-child, td:first-child { text-align: left; }
          th { background: #f6f8fa; }
          details.cluster { margin: 12px 0; border: 1px solid var(--border); border-radius: 8px; }
          details.cluster > summary { cursor: pointer; padding: 10px 12px; background: #f6f8fa; border-radius: 8px; }
          details.cluster[open] > summary { border-bottom: 1px solid var(--border); border-radius: 8px 8px 0 0; }
          .cluster-body { padding: 0 12px 12px; }
          details.file { margin: 12px 0; border: 1px solid var(--border); border-radius: 6px; }
          details.file > summary { cursor: pointer; padding: 8px 10px; }
          .file-path { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-weight: 600; }
          .diff { margin: 0; padding: 10px; overflow-x: auto; background: #f6f8fa; border-top: 1px solid var(--border); font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
          .diff-line { display: block; white-space: pre; }
          .diff-line.add { background: var(--add); }
          .diff-line.del { background: var(--del); }
          .diff-hunk { display: block; color: #0550ae; background: var(--hunk); }
          .diff-meta { display: block; color: var(--muted); font-weight: 600; }
          .marker { display: inline-block; width: 1ch; user-select: none; }
          .tok-comment { color: #6e7781; font-style: italic; }
          .tok-string { color: #0a3069; }
          .tok-symbol { color: #8250df; }
          .tok-number { color: #0550ae; }
          .tok-keyword { color: #cf222e; font-weight: 600; }
          .tok-constant { color: #953800; }
          .error-text { margin: 0; padding: 10px; border-top: 1px solid var(--border); background: #fff8c5; white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
          a { color: var(--accent); text-decoration: none; }
          a:hover { text-decoration: underline; }
          </style>
          </head>
          <body>
          <h1>#{h(title)}</h1>
          <p><span class="badge">#{h(mode)}</span> #{h(result_text)}</p>
          #{notes.map { |note| "<p class=\"muted\">#{h(note)}</p>" }.join}
          <div class="controls">
            <input id="search" type="search" placeholder="Filter by path...">
            <select id="repo-filter"><option value="">All repositories</option>#{repo_options}</select>
            <select id="status-filter">
              <option value="">All statuses</option>
              <option value="changed">Changed</option>
              <option value="added">Added</option>
              <option value="removed">Removed</option>
              <option value="error">New/continued errors</option>
              <option value="idempotence">Idempotence failures</option>
              <option value="validity">Validity failures</option>
            </select>
            <label><input id="only-diffs" type="checkbox"> Only files with diffs</label>
          </div>
          <h2>Summary</h2>
          <table>
            <thead><tr><th>Repo</th><th>Files</th><th>Changed</th><th>Added</th><th>Removed</th><th>New errors</th><th>Fixed errors</th><th>Idempotence</th><th>Validity</th></tr></thead>
            <tbody>
            #{repo_rows.map { |row| "<tr><td>#{h(row[:repo])}</td><td>#{row[:total]}</td><td>#{row[:changed]}</td><td>#{row[:added]}</td><td>#{row[:removed]}</td><td>#{row[:new_errors]}</td><td>#{row[:fixed_errors]}</td><td>#{row[:idempotence]}</td><td>#{row[:validity]}</td></tr>" }.join}
            </tbody>
          </table>
          <h2>Changes by pattern</h2>
          #{cluster_html}
          <script>
          (function () {
            var files = Array.prototype.slice.call(document.querySelectorAll('details.file'));
            var clusters = Array.prototype.slice.call(document.querySelectorAll('details.cluster'));
            var search = document.getElementById('search');
            var repo = document.getElementById('repo-filter');
            var status = document.getElementById('status-filter');
            var onlyDiffs = document.getElementById('only-diffs');
            function apply() {
              var q = (search.value || '').toLowerCase();
              var r = repo.value;
              var s = status.value;
              files.forEach(function (file) {
                var statuses = (file.dataset.status || '').split(/\\s+/);
                var show = (!q || file.dataset.path.toLowerCase().indexOf(q) !== -1) &&
                  (!r || file.dataset.repo === r) &&
                  (!s || statuses.indexOf(s) !== -1) &&
                  (!onlyDiffs.checked || file.dataset.hasDiff === 'true');
                file.style.display = show ? '' : 'none';
              });
              clusters.forEach(function (cluster) {
                var any = Array.prototype.slice.call(cluster.querySelectorAll('details.file')).some(function (file) {
                  return file.style.display !== 'none';
                });
                cluster.style.display = any ? '' : 'none';
              });
            }
            [search, repo, status, onlyDiffs].forEach(function (el) {
              el.addEventListener('input', apply);
              el.addEventListener('change', apply);
            });
          })();
          </script>
          </body>
          </html>
        HTML
      end
    end

    private

    def result_text
      return "No formatting changes." if total_changes.zero?

      repos_changed = files.map(&:repo).uniq.length
      shown = if files.length < total_changes
        "Showing #{files.length} of #{total_changes}"
      else
        "#{total_changes}"
      end

      "#{shown} changed file#{total_changes == 1 ? "" : "s"} across #{repos_changed} repositor#{repos_changed == 1 ? "y" : "ies"}."
    end

    def repo_rows
      @repo_rows ||= begin
        counts = {}
        repos.each do |repo|
          counts[repo.name] = {
            repo: repo.name,
            total: total_files[repo.name] || 0,
            changed: 0,
            added: 0,
            removed: 0,
            new_errors: 0,
            fixed_errors: 0,
            idempotence: 0,
            validity: 0
          }
        end

        files.each do |file|
          row = counts[file.repo]
          next unless row

          case file.kind
          when :added
            row[:added] += 1
          when :removed
            row[:removed] += 1
          else
            row[:changed] += 1
          end

          row[:new_errors] += 1 if new_error?(file)
          row[:fixed_errors] += 1 if fixed_error?(file)
          row[:idempotence] += 1 if idempotence_failure?(file)
          row[:validity] += 1 if validity_failure?(file)
        end

        counts.values
      end
    end

    def new_error?(file)
      new_status = file.new_status
      old_status = file.old_status
      %w[error timeout].include?(new_status) && !%w[error timeout].include?(old_status)
    end

    def fixed_error?(file)
      old_status = file.old_status
      new_status = file.new_status
      %w[error timeout].include?(old_status) && !%w[error timeout].include?(new_status)
    end

    def idempotence_failure?(file)
      (file.new_entry || {})["idempotent"] == false && (file.old_entry || {})["idempotent"] != false
    end

    def validity_failure?(file)
      (file.new_entry || {})["valid"] == false && (file.old_entry || {})["valid"] != false
    end

    def changed_size(file)
      (file.changed_lines || []).length
    end

    def top_files
      files.sort_by { |file| [-changed_size(file), file.repo, file.path] }.first(20)
    end

    def clusters_for(files)
      grouped = files.group_by { |file| cluster_signature(file) }
      grouped
        .map do |signature, cluster_files|
          {
            signature: signature,
            files: cluster_files.sort_by { |file| [file.repo, file.path] },
            changed: cluster_files.sum { |file| changed_size(file) }
          }
        end
        .sort_by { |cluster| [-cluster[:files].length, -cluster[:changed], cluster[:signature]] }
    end

    def cluster_signature(file)
      lines = (file.changed_lines || []).map do |line|
        line.strip.gsub(/\s+/, " ").gsub(/\b\d+\b/, "N").gsub(/\b[A-Za-z_]\w*\b/, "ID")
      end

      lines = lines.reject(&:empty?).uniq.sort.first(20)
      lines = ["error:#{file.new_status}"] if lines.empty?
      Digest::SHA256.hexdigest(lines.join("\n"))
    end

    def render_cluster(cluster)
      label = "identical change pattern"
      intro = "#{cluster[:files].length} file#{cluster[:files].length == 1 ? "" : "s"} · #{cluster[:changed]} changed line#{cluster[:changed] == 1 ? "" : "s"}"
      body = cluster[:files].map { |file| render_file(file) }.join("\n")
      <<~HTML
        <details class="cluster">
          <summary><strong>#{h(intro)}</strong> <span class="muted">#{h(label)}</span></summary>
          <div class="cluster-body">
          #{body}
          </div>
        </details>
      HTML
    end

    def render_file(file)
      statuses = [file.kind.to_s]
      statuses << "error" if new_error?(file) || fixed_error?(file)
      statuses << "idempotence" if idempotence_failure?(file)
      statuses << "validity" if validity_failure?(file)
      has_diff = file.diff && !file.diff.empty?
      badges = []
      badges << "<span class=\"badge\">#{h(file.kind)}</span>"
      if file.old_status || file.new_status
        badges <<
          "<span class=\"badge #{status_badge_class(file.new_status)}\">#{h(file.old_status || "-")} → #{h(file.new_status || "-")}</span>"
      end

      badges << "<span class=\"badge err\">idempotence</span>" if idempotence_failure?(file)
      badges << "<span class=\"badge err\">validity</span>" if validity_failure?(file)
      links = []
      if file.head_sha
        link = github_link(file.repo, file.head_sha, file.path)
        links << "<a href=\"#{h(link)}\">head source</a>" if link
      end

      if file.base_sha && file.base_sha != file.head_sha
        link = github_link(file.repo, file.base_sha, file.path)
        links << "<a href=\"#{h(link)}\">base source</a>" if link
      end

      body = if has_diff
        "<pre class=\"diff\">#{render_diff(file.diff)}</pre>"
      elsif file.new_entry && %w[error timeout].include?(file.new_entry["status"])
        "<pre class=\"error-text\">#{h(file.new_entry["error"] || file.new_entry["error_kind"] || "error")}</pre>"
      else
        "<p class=\"muted\" style=\"padding: 0 10px 10px\">No baseline formatted output is available for this file.</p>"
      end

      notes_html = Array(file.notes).map { |note| "<span class=\"muted\">#{h(note)}</span>" }.join(" ")
      <<~HTML
        <details class="file" data-repo="#{h(file.repo)}" data-path="#{h(file.path)}" data-status="#{h(statuses.join(" "))}" data-has-diff="#{has_diff}">
          <summary>
            <span class="file-path">#{h(file.repo)}/#{h(file.path)}</span>
            #{badges.join(" ")}
            <span class="muted">#{notes_html}</span>
            <span class="muted">(#{changed_size(file)} changed line#{changed_size(file) == 1 ? "" : "s"})</span>
            #{links.empty? ? "" : "· #{links.join(" · ")}"}
          </summary>
          #{body}
        </details>
      HTML
    end

    def status_badge_class(status)
      %w[error timeout].include?(status) ? "err" : "ok"
    end

    def render_diff(diff)
      diff.split("\n", -1).map { |line| render_diff_line(line) }.join("\n")
    end

    def render_diff_line(line)
      if line.start_with?("@@")
        "<span class=\"diff-hunk\">#{h(line)}</span>"
      elsif line.start_with?("--- ", "+++ ")
        "<span class=\"diff-meta\">#{h(line)}</span>"
      elsif line.start_with?("+", "-", " ")
        marker = line[0]
        content = line[1..] || ""
        cls = marker == "+" ? "add" : marker == "-" ? "del" : "ctx"
        "<span class=\"diff-line #{cls}\"><span class=\"marker\">#{h(marker)}</span>#{highlight(content)}</span>"
      else
        h(line)
      end
    end

    def highlight(line)
      out = +""
      position = 0
      line.scan(TOKEN_PATTERN) do
        match = Regexp.last_match
        out << h(line[position...match.begin(0)])
        klass = match.named_captures.compact.first&.first
        if klass
          out << "<span class=\"tok-#{klass}\">#{h(match[0])}</span>"
        else
          out << h(match[0])
        end

        position = match.end(0)
      end

      out << h(line[position..] || "")
      out
    end

    def github_link(repo_name, sha, path)
      repo = repos.find { |candidate| candidate.name == repo_name }
      return nil unless repo&.slug

      encoded = path.split("/").map { |part| CGI.escape(part) }.join("/")
      "https://github.com/#{repo.slug}/blob/#{sha}/#{encoded}"
    end

    def diffs_text
      files
        .map do |file|
          header = "### #{file.repo}/#{file.path}"
          body = file.diff && !file.diff.empty? ? file.diff : "(no diff available)\n"
          "#{header}\n\n#{body}"
        end
        .join("\n")
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end
  end
end
