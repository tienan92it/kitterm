# Plan: linux-tests-compile

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift | `swift test` | exit 0, 909 tests at the start |
| Linux build | the `facts.md` docker pipe with `swift build` | `Build complete`, 0 errors |
| Linux tests | the same pipe with `swift build --build-tests` | red at the start; `Build complete`, 0 errors after capability 2 |

Run one heavy build at a time. The Linux pipe re-points `.build/debug`
at the Linux tree; run it after `swift test`, never beside it
(`facts.md`).

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **The measurement.** Run `swift build --build-tests` in the Linux pipe on `main` and record every error, grouped by cause (`URLSession` without `FoundationNetworking`, `Bundle(for:)`, a Darwin-only import, anything else). No code change. | The grouped error list, with the count per cause and per file, in the round record. |
| 2 | **The tests compile on Linux.** Fix each cause the measurement found: `#if canImport(FoundationNetworking)` imports, and a Linux-only `#if` fence, named, for a case that cannot compile there. | The `--build-tests` pipe green; `swift test` on macOS with the same count or more; a `git grep` of every new fence in the note. |
| 3 | **CI compiles them.** The exact `ci.yml` change: `swift build --build-tests` in `linux-build`, and a comment that says what it compiles and what it does not run. Propose tier: the crew writes the diff, the human applies it. | The diff in the record; after the human applies it, one green `linux-build` run on the PR. |

Capability 1 first: a fix aimed at a list nobody measured misses the
causes nobody guessed.
