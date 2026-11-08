require_relative "test_helper"

class ReportTest < Minitest::Test
  def test_renders_summary_and_html
    old_output = "def x\n  1\nend\n"
    new_output = "def x\n  2\nend\n"
    diff = Corpus::Diff.unified(old_output, new_output, "base/a.rb", "head/a.rb")
    file = Corpus::Report::ReportFile.new(
      repo: "sample",
      path: "lib/a.rb",
      kind: :changed,
      old_status: "ok",
      new_status: "ok",
      old_entry: {"status" => "ok", "output_sha256" => "a"},
      new_entry: {"status" => "ok", "output_sha256" => "b"},
      old_output: old_output,
      new_output: new_output,
      input: old_output,
      base_sha: "a" * 40,
      head_sha: "b" * 40,
      diff: diff,
      changed_lines: Corpus::Diff.changed_lines(old_output, new_output),
      notes: ["output changed"]
    )
    repo = Corpus::Report::RepoInfo.new(
      name: "sample",
      url: "https://github.com/example/sample",
      slug: "example/sample",
      base_sha: "a" * 40,
      head_sha: "b" * 40,
      tier: "fast"
    )
    report = Corpus::Report.new(
      title: "test report",
      mode: "compare",
      files: [file],
      repos: [repo],
      total_files: {"sample" => 1},
      base_label: "base",
      head_label: "head",
      update_command: "ruby corpus/tool/corpus snapshot update"
    )

    summary = report.summary
    assert_includes(summary, "test report")
    assert_includes(summary, "sample/lib/a.rb")
    assert_includes(summary, "snapshot update")

    html = report.html
    assert_includes(html, "sample/lib/a.rb")
    assert_includes(html, "diff-line")
    assert_includes(html, "repo-filter")
    assert_includes(html, "https://github.com/example/sample/blob/#{"a" * 40}/lib/a.rb")
  end

  def test_renders_binary_output_containing_non_ascii
    old_output = "x = \"café\"\n".b
    new_output = "x = \"naïve\"\n".b
    diff = Corpus::Diff.unified(old_output, new_output, "base/a.rb", "head/a.rb")
    file = Corpus::Report::ReportFile.new(
      repo: "sample",
      path: "lib/a.rb",
      kind: :changed,
      old_status: "ok",
      new_status: "ok",
      old_entry: {"status" => "ok", "output_sha256" => "a"},
      new_entry: {"status" => "ok", "output_sha256" => "b"},
      old_output: old_output,
      new_output: new_output,
      input: old_output,
      base_sha: "a" * 40,
      head_sha: "b" * 40,
      diff: diff,
      changed_lines: Corpus::Diff.changed_lines(old_output, new_output),
      notes: ["output changed"]
    )
    repo = Corpus::Report::RepoInfo.new(
      name: "sample",
      url: "https://github.com/example/sample",
      slug: "example/sample",
      base_sha: "a" * 40,
      head_sha: "b" * 40,
      tier: "fast"
    )
    report = Corpus::Report.new(
      title: "test report",
      mode: "compare",
      files: [file],
      repos: [repo],
      total_files: {"sample" => 1}
    )

    assert_includes(report.html, "café")
    assert_includes(report.html, "naïve")

    Dir.mktmpdir do |dir|
      report.write(dir)
      assert_includes(File.read(File.join(dir, "diffs.txt")), "café")
    end
  end
end
