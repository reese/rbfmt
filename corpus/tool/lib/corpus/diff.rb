require "digest"

module Corpus
  module Diff
    class << self
      def ops(old_text, new_text)
        a = split_lines(old_text)
        b = split_lines(new_text)
        return a.map { |line| [:equal, line] } if a == b

        backtrack(trace_myers(a, b), a, b)
      end

      def changed_lines(old_text, new_text)
        ops(old_text, new_text).reject { |op, _line| op == :equal }.map { |_op, line| line }
      end

      def hunks(old_text, new_text, context: 3)
        rows = numbered_rows(ops(old_text, new_text))
        ranges = hunk_ranges(rows, context)
        ranges.map do |start_index, end_index|
          slice = rows[start_index...end_index]
          old_count = slice.count { |row| %i[equal delete].include?(row[:op]) }
          new_count = slice.count { |row| %i[equal insert].include?(row[:op]) }
          old_start = old_count.zero? ? [slice.first[:old_no] - 1, 0].max : slice.first[:old_no]
          new_start = new_count.zero? ? [slice.first[:new_no] - 1, 0].max : slice.first[:new_no]
          {
            header: "@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@",
            old_start: old_start,
            old_count: old_count,
            new_start: new_start,
            new_count: new_count,
            rows: slice
          }
        end
      end

      def unified(old_text, new_text, old_label = "a", new_label = "b", context: 3)
        hunks = hunks(old_text, new_text, context: context)
        return "" if hunks.empty?

        lines = ["--- #{old_label}", "+++ #{new_label}"]
        hunks.each do |hunk|
          lines << hunk[:header]
          hunk[:rows].each do |row|
            marker = case row[:op]
            when :equal
              " "
            when :delete
              "-"
            when :insert
              "+"
            end

            lines << "#{marker}#{row[:line]}"
          end
        end

        "#{lines.join("\n")}\n"
      end

      def split_lines(text)
        text.to_s.lines(chomp: true)
      end

      private

      def trace_myers(a, b)
        n = a.length
        m = b.length
        max = n + m
        v = {}
        trace = []
        (0..max).each do |d|
          trace << v.dup
          (-d..d).step(2) do |k|
            x = if k == -d || (k != d && v.fetch(k - 1, 0) < v.fetch(k + 1, 0))
              v.fetch(k + 1, 0)
            else
              v.fetch(k - 1, 0) + 1
            end

            y = x - k
            while x < n && y < m && a[x] == b[y]
              x += 1
              y += 1
            end

            v[k] = x
            return trace if x >= n && y >= m
          end
        end

        trace
      end

      def backtrack(trace, a, b)
        x = a.length
        y = b.length
        result = []
        (trace.length - 1).downto(0) do |d|
          v = trace[d]
          k = x - y
          prev_k = if k == -d || (k != d && v.fetch(k - 1, 0) < v.fetch(k + 1, 0))
            k + 1
          else
            k - 1
          end

          prev_x = v.fetch(prev_k, 0)
          prev_y = prev_x - prev_k
          while x > prev_x && y > prev_y
            result << [:equal, a[x - 1]]
            x -= 1
            y -= 1
          end

          next if d.zero?

          if x == prev_x
            result << [:insert, b[y - 1]]
            y -= 1
          else
            result << [:delete, a[x - 1]]
            x -= 1
          end
        end

        result.reverse
      end

      def numbered_rows(ops)
        old_no = 1
        new_no = 1
        ops.map do |op, line|
          row = {op: op, line: line, old_no: old_no, new_no: new_no}
          case op
          when :equal
            old_no += 1
            new_no += 1
          when :delete
            old_no += 1
          when :insert
            new_no += 1
          end

          row
        end
      end

      def hunk_ranges(rows, context)
        ranges = []
        index = 0
        while index < rows.length
          if rows[index][:op] == :equal
            index += 1
            next
          end

          finish = index
          finish += 1 while finish < rows.length && rows[finish][:op] != :equal
          start_index = [index - context, 0].max
          end_index = [finish + context, rows.length].min
          if !ranges.empty? && start_index <= ranges.last[1]
            ranges.last[1] = [ranges.last[1], end_index].max
          else
            ranges << [start_index, end_index]
          end

          index = finish
        end

        ranges
      end
    end
  end
end
