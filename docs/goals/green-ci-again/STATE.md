# STATE: green-ci-again

- Status: active
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-23, round 2 after: swift test 864, KittermCLITests 121, Linux build)
- Updated: 2026-09-23, round 2 closed

## Queue

1. `the-git-diff-says-why-it-failed` (capability 2).
3. `the-takeover-stops-racing` (capability 3).
4. `twenty-green-runs` (capability 4).

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `the-git-diff-says-why-it-failed` (capability 2), round 2, `b883574`
  and `7fd2219`. See `rounds/002.md`. Git was never reached: a sha
  pattern that demanded a digit dropped one short sha in a thousand.
- `the-wrapper-stops-taking-sigpipe` (capability 1), round 1, `4917187`.
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

Round 3, `the-takeover-stops-racing`, on the same branch.
