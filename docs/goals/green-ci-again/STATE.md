# STATE: green-ci-again

- Status: done
- Round: 4 of 3 in this budget (first budget)
- Rounds total: 4
- Last floor: green (2026-09-25, round 4: twenty `ci.yml` runs on `main`, through `e343f0b`)
- Updated: 2026-09-25, done

## Queue

Empty. All four capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `twenty-green-runs` (capability 4), round 4, PR #156. See
  `rounds/004.md`. Twenty green runs on `main`, `7c8479d` to `e343f0b`.
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

None. The five completion conditions of `goal.md` hold. Reopen with a
new queue item and `Status: active` when a flake returns.
