# Plan: green-ci-again

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift | `swift test` | exit 0 |
| CLI | `swift test --filter KittermCLITests` | exit 0 |
| Linux | the `facts.md` docker pipe | `Build complete`, 0 errors |
| Repeat | the round's own loop, `for i in $(seq 1 50)`, over the case under repair | 50 of 50 |

## How to reproduce a runner failure

The three families pass on this machine and fail on the runner, so a
round reproduces before it repairs. In order of cost:

1. Run the case 50 times locally under load (`swift test --filter <case>`
   with the machine busy). A local reproduction is the cheapest.
2. Push a branch whose workflow runs only that case, 20 times in one
   job. The runner is the environment that fails; a branch that runs
   nothing else costs four minutes.
3. Read the runner's own signal: exit 141 is `SIGPIPE`, which a
   subprocess takes when it writes to a pipe whose reader has gone.

A round that cannot reproduce in three tries records `world` as its
gap and stops; guessing at a fix for a failure you have not seen is
how a flake survives a repair.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **The statusline wrapper stops taking `SIGPIPE`.** Four of eight failures. Find why the wrapper's subprocess writes to a closed pipe on the runner and not here, and fix the cause in `StatuslineCommand` or the test's harness, whichever owns the pipe. | The case 50 of 50 on a runner branch; a test that fails before the fix; the record names the mechanism. |
| 2 | **`GoalCostTests` stops losing its git diffs.** Two failures, two cases. `filesChanged` shells out to `git diff --name-only <base>..<result>` in a temporary repository and returns nil on any failure, so a runner hiccup prints a dash and the table disagrees. Find what fails on the runner; make the helper say why it failed rather than swallowing it. | Both cases 50 of 50 on a runner branch; the helper's failure path covered by a test. |
| 3 | **`LiveTakeoverTests` stops racing.** One failure. Reproduce, then fix or name. | 50 of 50, or a named cause and one line in `facts.md`. |
| 4 | **Twenty green runs.** No new code; the foreman watches `main` and records. | `gh run list --workflow=ci.yml --limit 20` all green, in the record. |

Capability 1 first: it is half the failures. Capability 4 last, and it
is a measurement, not a change.
