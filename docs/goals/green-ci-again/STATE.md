# STATE: green-ci-again

- Status: waiting
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-09-23, round 3 after: swift test 864, KittermDaemonTests 680, Linux build)
- Updated: 2026-09-25, the new foreman counted the runs; the budget is spent

## Queue

1. `twenty-green-runs` (capability 4). A measurement, not a change: the
   foreman watches twenty consecutive `ci.yml` runs on `main`. Nineteen
   green as of 2026-09-25, through `72b8352`; the last red, `7f30556` on
   2026-09-21, predates the three fixes.

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `the-takeover-stops-racing` (capability 3), round 3, PR #150. See
  `rounds/003.md`. The test's defect, not the product's: it compared
  the ring with the client's stream at an unsynchronised instant.
- `the-git-diff-says-why-it-failed` (capability 2), round 2, PR #150. See `rounds/002.md`. Git was never reached: a sha
  pattern that demanded a digit dropped one short sha in a thousand.
- `the-wrapper-stops-taking-sigpipe` (capability 1), round 1, PR #150.
  See `rounds/001.md`. A product defect: the wrapper reported the
  writer's 141 instead of the previous statusline's own status. Four of
  the eight red runs were this.

## Direction

2026-09-23: CI went red on a documentation-only commit and again on the
branch beside it, and both passed on a re-run. The human asked for a
triage. The foreman measured thirty runs before writing this package:
8 red, and the red names six test cases, every one of them driving a
subprocess. A re-run is not a fix; a check that cries wolf costs more
than it saves.

## Next action

The first budget is spent, so the goal waits. PR #150 is merged. One
more green `ci.yml` run on `main` closes capability 4; the foreman then
records it and asks the human for direction.
