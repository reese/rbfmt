require_relative "test_helper"

class DiffTest < Minitest::Test
  def assert_reconstructs(old_text, new_text)
    old_lines = Corpus::Diff.split_lines(old_text)
    new_lines = Corpus::Diff.split_lines(new_text)
    rebuilt_old = []
    rebuilt_new = []
    Corpus::Diff.ops(old_text, new_text).each do |op, line|
      case op
      when :equal
        rebuilt_old << line
        rebuilt_new << line
      when :delete
        rebuilt_old << line
      when :insert
        rebuilt_new << line
      end
    end

    assert_equal(old_lines, rebuilt_old)
    assert_equal(new_lines, rebuilt_new)
  end

  def test_reconstructs_inputs
    cases = [
      ["", ""],
      ["a\n", ""],
      ["", "a\n"],
      ["a\nb\nc\n", "a\nx\nc\n"],
      ["one\ntwo\nthree\nfour\n", "zero\none\nthree\nfour\nfive\n"],
      ["a\nb\nc\nd\ne\n", "a\nc\nd\ne\n"]
    ]
    cases.each { |old_text, new_text| assert_reconstructs(old_text, new_text) }
  end

  def test_unified_diff
    diff = Corpus::Diff.unified("a\nb\nc\n", "a\nx\nc\n", "before", "after")
    assert_includes(diff, "--- before")
    assert_includes(diff, "+++ after")
    assert_includes(diff, "@@ -1,3 +1,3 @@")
    assert_includes(diff, "-b")
    assert_includes(diff, "+x")
  end

  def test_changed_lines
    assert_equal(["b", "x"], Corpus::Diff.changed_lines("a\nb\n", "a\nx\n"))
  end
end
