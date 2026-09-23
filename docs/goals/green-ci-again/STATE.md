# STATE: green-ci-again

- Status: active
- Round: 0 of 3 in this budget (first budget)
- Rounds total: 0
- Last floor: none yet
- Updated: 2026-09-23, created

## Queue

1. `the-wrapper-stops-taking-sigpipe` (capability 1).
2. `the-git-diff-says-why-it-failed` (capability 2).
3. `the-takeover-stops-racing` (capability 3).
4. `twenty-green-runs` (capability 4).

## Failures

None.

## Proposals waiting on the human

None.

## Done

Nothing yet.

## Direction

2026-09-23: CI went red on a documentation-only commit and again on the
branch beside it, and both passed on a re-run. The human asked for a
triage. The foreman measured thirty runs before writing this package:
8 red, and the red names six test cases, every one of them driving a
subprocess. A re-run is not a fix; a check that cries wolf costs more
than it saves.

## Next action

Round 1, `the-wrapper-stops-taking-sigpipe`, on
`green-ci-again/round-1` from `origin/main`.
