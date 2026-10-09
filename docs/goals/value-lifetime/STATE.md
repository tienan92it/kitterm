# STATE: value-lifetime

- Status: active
- Round: 1 of 3 in this budget (second budget)
- Rounds total: 4
- Last floor: green (2026-10-09, round 4 after: vitest 1662)
- Updated: 2026-10-09, direction check: the median rule for the base day, a second budget of 3

## Queue

1. `lifetime-chart` (capability 4), PR #188.

## Failures

None.

## Proposals waiting on the human

None. 2026-10-09: the human chose the base-day rule (seven days, each
at least 25% of the median daily spend).

## Done

- `base-day-rule`, round 4, PR #188. See `rounds/004.md`. The base day
  follows the human's median rule.
- `lifetime-series`, round 3, PR #188. See `rounds/003.md`. The pure
  series module, with the base-day rule fix queued.
- `lifetime-design`, round 2, PR #188. See `rounds/002.md`. The human
  approved TOTALS and UNIT COSTS at 4b8379e.
- `yield-per-day`, round 1, PR #188. See `rounds/001.md`.
  `GET /api/yield/daily` answers merged work per day.

## Next action

Round 5: `lifetime-chart` from `plan.md` row 4; proof: the foundation's
proofs and a check against the live daemon.
