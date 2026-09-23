# Goal: a red CI means a broken change

## Objective

Today it does not. Eight of the last thirty CI runs were red, and the
red told the human nothing: five were one test that fails on the
runner and passes everywhere else, and two more were a documentation
check that a merged pull request had already satisfied. A person who
sees red has to re-run the job to learn whether the change is at
fault, which is the opposite of what the check is for.

After this goal, a red `test` job means the change under it is broken.
Every remaining flake is either fixed at its cause or named, with its
measured rate, in `docs/goals/facts.md`.

## What was measured, 2026-09-23

Thirty runs of `ci.yml`: 21 green, 8 red, one with no conclusion. The
eight, by the test that failed:

| Test | Runs | What it does |
|---|---|---|
| `StatuslineInstallTests.testTheWrapperIsQuickAndQuietWithoutADaemon` | 4 | runs the installed wrapper as a subprocess; exit 141, which is `SIGPIPE` |
| `GoalsLayoutDocsTests.testTheLoopFilesCarryTheSameRuleSentences` | 2 | reads five files; both runs predate the pull request that made them agree |
| `GoalCostTests` (two cases) | 2 | build a git repository in a temporary directory and shell out to `git` |
| `LiveTakeoverTests.testExecTakeoverKeepsPidSessionStreamAndEpoch` | 1 | execs a daemon over itself and reads the stream |

Every one of the six flaking cases drives a subprocess. None failed
through the suite's own `waitForExit` helper, which fails loudly with
its own message; so none is a plain timeout.

## Exclusions

- No test is deleted, skipped, or given a retry to make the suite
  green. A retry hides the defect this goal exists to find.
- No assertion is weakened. A test that proves less is a worse test.
- The goal does not change what the product does, unless a flake turns
  out to be a real defect in the product; then that fix is its own
  round and the record says so.

## Completion condition

All five hold:

1. `StatuslineInstallTests`'s wrapper case passes 50 runs in a row on
   a macOS runner, and the record names why it took `SIGPIPE`.
2. `GoalCostTests`'s two cases pass 50 runs in a row on a runner, and
   the record names why `git diff --name-only` returned nothing.
3. `LiveTakeoverTests`'s case passes 50 runs in a row on a runner, or
   its cause is named and it is the only case left in `facts.md`.
4. Twenty consecutive `ci.yml` runs on `main` are green.
5. Every flake fixed is fixed at its cause: the record names the
   mechanism, and a test fails before the fix and passes after.

The floor (`swift test`, the Linux docker pipe, `swift test --filter
KittermCLITests`) is green at every step.
