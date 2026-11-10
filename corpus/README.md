# rubyfmt corpus regression tool

This directory contains a pinned, open-source Ruby corpus and the tooling used to
answer one question:

> Did this change alter how rubyfmt formats real-world Ruby code, and if so, how?

The tool has two jobs:

1. **CI check**: format the corpus with the working-tree rubyfmt and compare the
   result to a committed snapshot. Any output/status change fails CI and produces
   an HTML/Markdown report.
2. **Local compare**: build rubyfmt at a baseline and at the working tree, format
   the corpus with both, and show the differences.

Corpus sources and formatted output are never committed. Only the manifest and
per-file hashes live in git.

## Requirements

- Ruby **4.0.7** (or 3.3+) with the **Prism 2.1.0** gem installed, to match the
  committed snapshot. Ruby 4.0.7 ships Prism 1.8.1, so install the gem explicitly:
  `gem install prism -v 2.1.0 --no-document`.
  Verify with `ruby -e 'require "prism"; puts Prism::VERSION'`.
- Git.
- Rust/Cargo for building rubyfmt and for `compare`.
- A release rubyfmt binary: `cargo build --release --locked`
  (the binary is `target/release/rubyfmt-main`).

The snapshot records the Ruby/Prism version used to produce validity results.
`check` refuses to run when the Prism version differs, so CI and local runs do
not silently disagree. Pass `--rubyfmt` or set `RUBYFMT` to use a different
binary.

## Quick start

```sh
cargo build --release --locked

ruby corpus/tool/corpus validate
ruby corpus/tool/corpus fetch --tier fast
ruby corpus/tool/corpus check --tier fast --rubyfmt target/release/rubyfmt-main
```

The full corpus:

```sh
ruby corpus/tool/corpus snapshot update --rubyfmt target/release/rubyfmt-main
ruby corpus/tool/corpus check --tier full --rubyfmt target/release/rubyfmt-main
```

`--tier fast` selects the projects marked `tier: fast` (a small PR subset).
`--tier full` and `--tier all` select every project.

## Commands

Run the tool as `ruby corpus/tool/corpus <command>` or put `corpus/tool` on your
`PATH` and run `corpus <command>`.

### `validate`

```sh
ruby corpus/tool/corpus validate
```

Validates `corpus.yml` (unique names, full 40-character SHAs, known kinds/tiers,
valid globs) and, when present, `snapshot/` (version, config, per-repo files and
rollups, global rollup).

### `fetch`

```sh
ruby corpus/tool/corpus fetch [--tier fast|full] [--repo NAME] [--jobs N]
```

Fetches each pinned commit into
`~/.cache/rubyfmt-corpus/repos/<name>/<sha>/`. The fetcher is shallow, then
verifies that `HEAD` is exactly the pinned SHA. It is idempotent. Override the
cache with `RUBYFMT_CORPUS_CACHE`.

### `bump`

```sh
ruby corpus/tool/corpus bump NAME [SHA_OR_REF]
```

Updates a project's SHA in place (defaults to the remote `HEAD`). The manifest's
comments and YAML anchors are preserved; only the `sha:` line changes. After a
bump you must also update the snapshot:

```sh
cargo build --release --locked
ruby corpus/tool/corpus snapshot update --rubyfmt target/release/rubyfmt-main
```

### `run`

```sh
ruby corpus/tool/corpus run [--tier ...] [--repo NAME] \
  [--output-dir DIR] [--json PATH] [--checks idempotence,validity,ast|none]
```

Formats the selected corpus and emits a result JSON (`-` writes it to stdout).
`--output-dir` retains the formatted output; it is useful for debugging.

### `check`

```sh
ruby corpus/tool/corpus check --tier fast --rubyfmt target/release/rubyfmt-main
```

Runs the corpus, compares against `corpus/snapshot/`, writes
`corpus-report/{report.html,summary.md,results.json,outputs/}`, prints a summary,
and exits non-zero when anything differs. This is the CI entry point.

Useful options:

- `--report-dir DIR` (default `corpus-report`)
- `--update` to update the snapshot instead of failing
- `--no-report` to skip the HTML report
- `--keep-output` to keep formatted outputs next to the report (they are removed
  by default after the self-contained report is written)
- `--full-checks` to re-run idempotence/validity for unchanged files too
- `--checks ...`, `--header-mode ...`, `--timeout ...`, `--jobs ...`

By default `check` reuses the snapshot's idempotence/validity results for files
whose formatted output is unchanged, and only re-checks changed files. This keeps
normal CI checks fast. Use `--full-checks` (or `snapshot update`) to validate
every file from scratch, especially when changing second-pass or validity
behavior.

### `snapshot update`

```sh
ruby corpus/tool/corpus snapshot update --rubyfmt target/release/rubyfmt-main
```

Regenerates the committed snapshot. By default it updates all projects. A partial
selection merges into the existing snapshot; `--replace` discards projects that
are not selected.

### `compare`

```sh
ruby corpus/tool/corpus compare
ruby corpus/tool/corpus compare --base origin/trunk --head target/release/rubyfmt-main
ruby corpus/tool/corpus compare --base /path/to/base-binary --path 'app/models/**' --limit 50
```

`compare` builds the baseline automatically in a temporary git worktree on first
use; you do not need to build it yourself.

- Default base: the merge-base with `origin/main`, `origin/trunk`, `trunk`, or
  `main` (first one that exists). The default branch of this fork is `trunk`.
- Default head: the current working tree.
- `--base`/`--head` accept a git ref or a prebuilt binary path.
- If you pass an explicit remote ref such as `origin/main`, make sure it exists
  locally (`git fetch origin` first).
- Baseline refs are built in a temporary git worktree; binaries are cached by
  commit SHA under `~/.cache/rubyfmt-corpus/builds`, and results by binary hash +
  manifest digest + flags under `~/.cache/rubyfmt-corpus/results`.
- Reports are written to `corpus-report/compare/` (self-contained HTML +
  Markdown + JSON).
- Filters: `--repo NAME`, `--path GLOB`, `--only-changed` (the default behavior), `--limit N`.
- `--no-build` uses existing/cached binaries; `--no-fail` exits zero even when
  differences exist.

## Corpus manifest

`corpus/corpus.yml` is a YAML list. Each entry has:

```yaml
- name: rails # unique, lowercase
  url: https://github.com/rails/rails
  sha: 8384b38f150663b2fd510926f38a2958bd5ac1db # full 40-character SHA
  kind: framework # app | gem | framework | tool (informational)
  tier: full # fast (PR subset) | full
  include:
    - "**/*.rb"
    - "**/*.rake"
    - "**/*.gemspec"
    - "**/Rakefile"
    - "**/Gemfile"
    - "**/config.ru"
  exclude:
    - "**/.git/**"
    - "**/vendor/**"
    - "**/node_modules/**"
    - "**/tmp/**"
    - "**/coverage/**"
    - "**/fixtures/**"
```

Globs support `*`, `?`, `**`, character classes, and `{a,b}` alternation.
`**/` matches zero or more directories. Files are sorted lexicographically before
formatting.

To add a project: append an entry, run `fetch`, then `snapshot update`.

## Snapshot format

`corpus/snapshot/` is deliberately stable and diff-friendly. Each repository has
its own file, so a formatting change only touches the affected repo's JSON:

```text
corpus/snapshot/
  index.json              version, config, global rollup, repo list
  repos/activeadmin.json
  repos/rails.json
  ...
```

Each `repos/<name>.json` contains the pinned `sha`, the repo rollup, and its file
entries:

```json
{
  "sha": "...",
  "rollup": "...",
  "files": {
    "app/models/user.rb": {"status":"ok","output_sha256":"..."},
    "lib/example.rb": {"status":"error","error_kind":"syntax_error","error_sha256":"..."}
  }
}
```

The snapshot is stable and diff-friendly:

- repos and paths are sorted;
- each file entry is on one line;
- only hashes/status/check failures are stored;
- per-repo and global rollups are SHA-256 over the sorted entries;
- `config` records `header_mode`, `checks`, `prism_version`, and `ruby_version`.

Known failures are recorded as error entries, so a pre-existing failure is not
new noise. A new crash or a changed error message is a change. Skipped files
(`# rubyfmt: false` with `--header-mode opt-out`) are recorded as
`{"status":"skipped"}`.

Intentional formatting changes are accepted by updating the snapshot in the same
PR:

```sh
ruby corpus/tool/corpus snapshot update --rubyfmt target/release/rubyfmt-main
git add corpus/snapshot
```

## Correctness checks

- **idempotence** (default): format the formatted output again and compare bytes.
- **validity** (default): parse the input and output with Prism; report files
  where the input parsed but the output does not. Files whose input does not parse
  are not reported.
- **ast** (opt-in, non-blocking): compare normalized Prism ASTs of input and
  output; formatting-only differences are ignored. Stored in the `run --json`
  result but not used for snapshot pass/fail.

```sh
ruby corpus/tool/corpus run --checks idempotence,validity,ast ...
```

The snapshot records only idempotence/validity failures. The `ast` check is not
part of the snapshot.

## Determinism

The runner is designed to be byte-identical for the same binary + corpus:

- every repo is pinned to a SHA; checkouts force `core.autocrlf=false` and
  `core.eol=lf`;
- files and results are sorted;
- formatting goes through stdin with a fixed working directory, locale, `TZ`,
  `NO_COLOR`, and `RUST_BACKTRACE=0`;
- stderr is normalized (ANSI stripped, cache/repo/cwd paths replaced, rubyfmt
  source paths replaced);
- only formatted-output bytes and normalized errors are hashed;
- timings and paths are not in the snapshot;
- validity results are tied to the recorded Ruby/Prism version.

If you change `header_mode`, `checks`, or the Ruby/Prism version, regenerate the
snapshot and commit the config change with it.

## CI

`.github/workflows/corpus.yml`:

- builds `target/release/rubyfmt-main`;
- uses Ruby 4.0.7 and installs the Prism 2.1.0 gem;
- caches `~/.cache/rubyfmt-corpus/repos` keyed on `corpus/corpus.yml`;
- runs `--tier fast` on PRs/pushes and `--tier full` on the weekly schedule and
  manual dispatch;
- uploads `corpus-report` as an artifact, appends `summary.md` to the job
  summary, and updates a sticky PR comment (when running on a pull request);
- fails on snapshot mismatch.

On failure, review `corpus-report/report.html`. It groups equivalent change
patterns, links files at the pinned GitHub SHA, and filters by repo/path/status.
If the changes are intentional, update the snapshot and commit it.

The full corpus is 28 projects and ~30,000 files. After the repo cache is warm, a
normal `check` (which reuses check results for unchanged files) takes roughly a
minute on a fast machine; `--full-checks` or `snapshot update` takes about 2.5
minutes. The fast tier is under 10 seconds. CI uses fewer jobs to keep runner
load predictable.

## Caching and disk use

Everything is under `~/.cache/rubyfmt-corpus` (override with
`RUBYFMT_CORPUS_CACHE`):

- `repos/<name>/<sha>/` — pinned checkouts;
- `results/<key>/` — local `compare` results and outputs;
- `builds/<sha>-<platform>/` — cached baseline binaries;
- `worktrees/` and `targets/` — temporary build dirs (removed after a build).

Delete the cache directory at any time to reclaim space; the next run will
fetch/build again. `corpus-report/` is gitignored.

## Tests

```sh
ruby corpus/tool/test/run.rb
```

The tests cover manifest validation/bumping, glob matching, Myers diff and
unified output, snapshot copy/serialization/rollups, runner behavior (timeouts,
panics, header opt-in/out, idempotence/validity), and HTML report rendering.

## Layout

```text
corpus/
  corpus.yml          committed manifest
  snapshot/           committed snapshot, one file per repo
    index.json        version, config, global rollup, repo list
    repos/*.json      per-repo sha, rollup, and file entries
  README.md
  tool/
    corpus            executable entry point
    corpus.rb
    lib/corpus/*.rb   implementation
    test/             minitest suite
```

## Limitations and non-goals

- The CI check does not build a baseline binary. It compares to the committed
  snapshot. The snapshot stores hashes, not output, so a CI report for a changed
  file shows the input vs. the new formatted output. Use `compare` locally for
  base-vs-head formatted diffs.
- The corpus is intentionally small (28 projects), not a RubyGems-wide sweep.
- The tool does not run Ruby code from the corpus. It only parses/format files.
- Corpus sources are fetched at test time and are not redistributed; only hashes
  are committed.
- Formatting style is not judged. The tool reports changes; reviewers decide
  whether they are correct.
