# STATE: green-ci

- Status: active
- Round: 0 of 3 in this budget
- Rounds total: 0
- Last floor: green (2026-09-09, main at 3c14451, locally)
- Updated: 2026-09-09

## Queue

1. `paced-input-race` (capability 1)
2. `takeover-race` (capability 2)
3. `wait-helper-audit` (capability 3)

## Failures

None yet in this goal. The two failures it exists to remove are named in
`goal.md` and reproduced by `corpus/01-red-ci.md`.

## Proposals waiting on the human

None.

## Done

None.

## Next action

Round 1: `paced-input-race` and `takeover-race` may run in one round,
since the two tests are independent and each is small. Reproduce both
under load first, then fix, then 20 runs each.
