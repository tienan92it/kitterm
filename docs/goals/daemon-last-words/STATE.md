# STATE: daemon-last-words

- Status: active
- Round: 0 of 3 in this budget (first budget)
- Rounds total: 0
- Last floor: green (2026-09-10, main at 2eb49c4)
- Updated: 2026-09-10

## Queue

1. `record-how-a-run-ends` (capability 1)
2. `report-the-previous-run` (capability 2)
3. `say-it-on-the-page` (capability 3)

## Failures

None.

## Proposals waiting on the human

None.

## Done

None.

## Next action

Round 1: `record-how-a-run-ends` from `plan.md` row 1; proof: unit tests
over the file's states and a SIGTERM path that writes `stopped`. Branch
`goals/record-how-a-run-ends` off `main`.
