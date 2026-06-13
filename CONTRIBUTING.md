# Contributing to peat-flutter

Thanks for your interest in contributing! `peat-flutter` is a Flutter FFI plugin
that wraps the [peat](https://github.com/defenseunicorns) mesh protocol stack
(`peat-schema`, `peat-protocol`, `peat-mesh`, `peat-btle`) and exposes it to Dart
via `peat-ffi` (UniFFI). This document describes how to set up your environment,
make changes, and submit them for review.

By participating in this project you agree to abide by our
[Code of Conduct](./CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report bugs** and **request features** via
  [GitHub Issues](../../issues/new/choose).
- **Improve documentation** in `README.md` or `docs/`.
- **Submit code** via pull requests (see the workflow below).

## Development environment

You will need:

- [Flutter](https://docs.flutter.dev/get-started/install) `>=3.3.0` with Dart
  SDK `^3.9.2`.
- [`just`](https://github.com/casey/just) to run the project tasks (see
  [`justfile`](./justfile)).
- A checkout of the [`peat`](https://github.com/defenseunicorns) Rust workspace
  as a sibling directory (default `../peat`, override with
  `PEAT_WORKSPACE_DIR`). This is only needed when regenerating bindings or
  building the native `peat-ffi` library from source.

Per-platform native toolchains (only needed when building `peat-ffi` yourself):

- **Android:** `cargo install cargo-ndk` + the Android NDK (`ANDROID_NDK_HOME`).
- **iOS / macOS:** Xcode (macOS host only).
- **Linux / Windows:** CMake (the CMake build shells out to `cargo`).

> The committed `lib/src/generated/` and `lib/src/proto/` sources let pub.dev
> consumers build without the Rust / UniFFI / `protoc` toolchain. You only need
> those tools when changing the native surface.

## Common tasks

```bash
just analyze          # dart analyze lib/
just gen-proto        # regenerate Dart proto stubs from peat-schema
just check-bindings   # verify generated FFI bindings against libpeat_ffi
just regen            # gen-proto + check-bindings
just build-host       # build peat-ffi for the native host
just build-android    # build peat-ffi for all Android ABIs
just build-ios        # build the PeatFFI.xcframework (macOS only)
just build-macos      # build the universal macOS dylib (macOS only)
```

Run the analyzer and the test suite before opening a PR:

```bash
dart analyze
flutter test
cd example && flutter test
```

## Making changes

1. **Fork** the repository and create a topic branch off `main`
   (e.g. `feat/short-description` or `fix/short-description`).
2. Make your change. Keep commits focused and write clear commit messages.
3. **License headers:** every new source file MUST carry the Apache-2.0 SPDX
   header (see [Licensing](#licensing) below).
4. Ensure `dart analyze` is clean and tests pass.
5. Update `CHANGELOG.md` and any relevant docs.

## Pull request process

1. Open a PR against `main` and fill out the
   [pull request template](./.github/pull_request_template.md).
2. CI (analyze, format, tests, license-header check) must pass.
3. We use a **squash-and-merge** strategy. A PR requires at least **one
   approval** from a member of [`CODEOWNERS`](./CODEOWNERS) before it can merge.
4. A maintainer will merge once review is complete.

## Licensing

This project is licensed under the [Apache License 2.0](./LICENSE). By
contributing, you agree that your contributions will be licensed under the same
terms.

Every source file must begin with the standard header:

```dart
// Copyright 2026 Defense Unicorns
// SPDX-License-Identifier: Apache-2.0
```

Use the comment syntax appropriate to the file's language. When you modify an
existing file in a later year, expand the year to a range
(e.g. `Copyright 2026-2027 Defense Unicorns`). Do **not** use `-Present` or
`-Now`.

## Questions

Open a [discussion or issue](../../issues) — we're happy to help.
