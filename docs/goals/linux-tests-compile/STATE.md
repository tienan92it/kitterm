# STATE: linux-tests-compile

- Status: waiting
- Round: 0 of 3 in this budget (first budget)
- Rounds total: 0
- Last floor: green (2026-09-28, main at d3546d9: swift test 909)
- Updated: 2026-09-28, written by the foreman on the human's word

## Queue

1. `the-measurement` (capability 1).
2. `the-tests-compile-on-linux` (capability 2).
3. `ci-compiles-them` (capability 3).

## Failures

None.

## Proposals waiting on the human

None.

## Done

None.

## Direction

2026-09-28: the human chose this goal from the foreman's plan (the
decision table after v0.33.0). The foreman drafted `goal.md` and
`plan.md`; the status stays `waiting` until the human approves them by
merging this package, then the foreman sets it `active`.

## Next action

Round 1: `the-measurement` from `plan.md` row 1; proof: the grouped error list in the record. Spawn one crew
session in a worktree with labels `crew:linux-tests-compile`, `goal:linux-tests-compile`,
`round:1`, `task:the-measurement`, and no input. Run the floor, start `claude`,
and send the row.
