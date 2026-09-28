# Goal: the Linux CI job compiles the tests

## Objective

Today it compiles `Sources/` only. The `linux-build` job in
`.github/workflows/ci.yml` runs `swift build`, so no file under `Tests/`
has ever compiled on Linux. A test that uses an API the Linux toolchain
does not have passes CI and fails on the first Linux machine that builds
the tests. Four rounds have written "the Linux build caught a `Sendable`
error"; each one was a `Sources/` error, and a `Tests/` error of the same
class would pass unseen (`steady-suite` round 1).

After this goal, the `linux-build` job compiles every test target, and a
red `linux-build` names a file that does not compile on Linux.

## What was measured, 2026-09-28

On `main` at `d3546d9`: 111 test files. 33 of them use `URLSession`, and
none imports `FoundationNetworking`, which is where corelibs-foundation
keeps `URLSession` on Linux. 35 use `Bundle(for:)`. The comment in
`ci.yml` still says "seven test files use Bundle(for:)".

## Exclusions

- No test runs on Linux. `swift test` on Linux needs every
  `Bundle(for:)` case to work under corelibs-XCTest, which is a
  different goal. This goal compiles the tests; it does not run them.
- No test is deleted, skipped on macOS, or weakened to make it compile.
  A case that cannot compile on Linux is fenced with `#if` for Linux
  alone, and the fence names the API it lacks.
- No product change under `Sources/`, unless a `Sources/` API that a
  test uses is itself missing on Linux; then that fix is its own round.
- `.github/workflows/ci.yml` is Propose tier. The crew writes the exact
  change in its note, and the human applies it.

## Completion condition

All four hold on a build from `main`:

1. The `facts.md` docker pipe with `swift build --build-tests` in
   `swift:6.1` reports `Build complete` with 0 errors.
2. The `linux-build` job in `ci.yml` runs `swift build --build-tests`,
   and its comment says what it compiles and what it does not run.
3. Every `#if` fence added for Linux names the API it lacks, and
   `git grep` finds no fence that also turns a case off on macOS.
4. `swift test` on macOS runs the same number of tests as before the
   goal, or more.

The floor (`swift test` on macOS, the Linux docker pipe with
`--build-tests`) is green at every step after capability 2.
