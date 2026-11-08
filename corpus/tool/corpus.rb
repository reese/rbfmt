require_relative "lib/corpus"

exit(Corpus::CLI.new(ARGV).run)
