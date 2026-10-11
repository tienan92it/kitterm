# STATE: value-lifetime

- Status: active
- Round: 0 of 3 in this budget (third budget)
- Rounds total: 6
- Last floor: green (2026-10-10, round 6 after: vitest 1732, PR CI on f3d2751)
- Updated: 2026-10-11, a third budget on the human's word: the legend, the range, and `all`

## Queue

1. `legend-and-range` (capability 5), PR #190.
2. `all-range` (capability 6)

## Failures

None.

## Proposals waiting on the human

None. 2026-10-09: the human chose the base-day rule (seven days, each
at least 25% of the median daily spend).

## Done

- `chart-polish`, round 6, PR #189. See `rounds/006.md`. The titles get
  room, and the tooltip fits, stays in its chart and shows real values.
- `lifetime-chart`, round 5, PR #188. See `rounds/005.md`. TOTALS and
  UNIT COSTS draw under VALUE.
- `base-day-rule`, round 4, PR #188. See `rounds/004.md`. The base day
  follows the human's median rule.
- `lifetime-series`, round 3, PR #188. See `rounds/003.md`. The pure
  series module, with the base-day rule fix queued.
- `lifetime-design`, round 2, PR #188. See `rounds/002.md`. The human
  approved TOTALS and UNIT COSTS at 4b8379e.
- `yield-per-day`, round 1, PR #188. See `rounds/001.md`.
  `GET /api/yield/daily` answers merged work per day.

## Next action

Round 7: `legend-and-range` from `plan.md` capability 5.
