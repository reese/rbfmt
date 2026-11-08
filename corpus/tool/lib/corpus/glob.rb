module Corpus
  module Glob
    @cache = {}
    @mutex = Mutex.new

    class << self
      def regex(pattern)
        @mutex.synchronize do
          @cache[pattern] ||= Regexp.new("\\A#{compile(pattern)}\\z")
        end
      end

      def match?(pattern, path)
        regex(pattern).match?(path)
      end

      def any_match?(patterns, path)
        patterns.any? { |pattern| match?(pattern, path) }
      end

      private

      def compile(pattern)
        out = +""
        i = 0
        while i < pattern.length
          char = pattern[i]
          case char
          when "\\"
            if i + 1 < pattern.length
              out << Regexp.escape(pattern[i + 1])
              i += 2
            else
              out << Regexp.escape("\\")
              i += 1
            end

          when "*"
            if pattern[i + 1] == "*"
              if pattern[i + 2] == "/"
                out << "(?:.*/)?"
                i += 3
              else
                out << ".*"
                i += 2
              end
            else
              out << "[^/]*"
              i += 1
            end

          when "?"
            out << "[^/]"
            i += 1
          when "["
            close = pattern.index("]", i + 1)
            if close
              content = pattern[(i + 1)...close]
              content = "^#{content[1..]}" if content.start_with?("!")
              out << "[#{content}]"
              i = close + 1
            else
              out << Regexp.escape(char)
              i += 1
            end

          when "{"
            close = pattern.index("}", i + 1)
            if close
              alternatives = pattern[(i + 1)...close].split(",", -1)
              out << "(?:#{alternatives.map { |a| compile(a) }.join("|")})"
              i = close + 1
            else
              out << Regexp.escape(char)
              i += 1
            end
          else
            out << Regexp.escape(char)
            i += 1
          end
        end

        out
      end
    end
  end
end
