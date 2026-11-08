module Corpus
  ROOT = File.expand_path("../../..", __dir__)
  CORPUS_DIR = File.join(ROOT, "corpus")
  DEFAULT_MANIFEST_PATH = File.join(CORPUS_DIR, "corpus.yml")
  DEFAULT_SNAPSHOT_PATH = File.join(CORPUS_DIR, "snapshot.json")
  DEFAULT_CACHE_ROOT = ENV["RUBYFMT_CORPUS_CACHE"] || File.join(Dir.home, ".cache", "rubyfmt-corpus")
end

require_relative "corpus/glob"
require_relative "corpus/manifest"
require_relative "corpus/cache"
require_relative "corpus/snapshot"
require_relative "corpus/runner"
require_relative "corpus/diff"
require_relative "corpus/report"
require_relative "corpus/binary"
require_relative "corpus/compare"
require_relative "corpus/cli"
