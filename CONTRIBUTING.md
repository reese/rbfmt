# Contributing

## Requirements

Make sure you have a recent-ish Rust/Cargo toolchain. You can [check what version is used in CI](https://github.com/search?q=repo%3Afables-tales%2Frubyfmt%20toolchain%3A&type=code), but most recent versions should work fine.

# Day to day tasks

## Running the tests

`cargo test`

in particular `cargo test --test fixtures_test` is what I use for ongoing
development when I'm testing a new feature, which I usually start by committing
a new fixture.

## Corpus Regression Testing

Formatting regressions are checked against a pinned, open-source Ruby corpus.
The corpus manifest, snapshot, CLI, and reports live in [`corpus/`](./corpus/README.md).

```sh
cargo build --release --locked
ruby corpus/tool/corpus check --tier fast --rubyfmt target/release/rubyfmt-main
ruby corpus/tool/corpus compare
```

## Autoformatting

Run `make fmt` to cleanup formatting for CI

## Linting

Run `make lint`
