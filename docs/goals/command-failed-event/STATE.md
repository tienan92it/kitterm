# STATE: command-failed-event

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-28, round 1 after: swift test 923, Linux build, bench p95 2.74 ms)
- Updated: 2026-09-28, round 1 closed

## Queue

1. `the-contract-written-down` (capability 2).

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `the-event` (capability 1), round 1, `ade5e7e`. See `rounds/001.md`.
  The feed carries `command.failed {index, exit, command?}` for a
  failed command in an orchestrated session; the review caught a
  duplicate-mark defect before the merge.

## Direction

2026-09-28: the human chose this goal from the foreman's plan (the
decision table after v0.33.0). The foreman drafted `goal.md` and
`plan.md`; the status stays `waiting` until the human approves them by
merging this package, then the foreman sets it `active`. The human
merged PR #163 on 2026-09-28.

## Next action

Round 2: `the-contract-written-down` from `plan.md` row 2, on the same
branch; proof: the `ForemanSkills` golden test and the sentence checks
green, and the three texts in the note.
