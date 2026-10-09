# STATE: value-lifetime

- Status: active
- Round: 0 of 3 in this budget (second budget)
- Rounds total: 3
- Last floor: green (2026-10-09, round 3 after: vitest 1658, PR CI linux-build on 6acbb80)
- Updated: 2026-10-09, direction check: the median rule for the base day, a second budget of 3

## Queue

1. `base-day-rule` (capability 3, the human's rule of 2026-10-09), PR #188.
2. `lifetime-chart` (capability 4)

## Failures

None.

## Proposals waiting on the human

None. 2026-10-09: the human chose the base-day rule (seven days, each
at least 25% of the median daily spend).

## Done

- `lifetime-series`, round 3, PR #188. See `rounds/003.md`. The pure
  series module, with the base-day rule fix queued.
- `lifetime-design`, round 2, PR #188. See `rounds/002.md`. The human
  approved TOTALS and UNIT COSTS at 4b8379e.
- `yield-per-day`, round 1, PR #188. See `rounds/001.md`.
  `GET /api/yield/daily` answers merged work per day.

## Next action

Round 4: `base-day-rule`: `baseDayOf` takes the human's median rule,
and the fixture holds 23 Aug as $0.09, the real value.
