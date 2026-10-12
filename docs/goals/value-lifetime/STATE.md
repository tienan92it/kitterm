# STATE: value-lifetime

- Status: done
- Round: 2 of 3 in this budget (third budget)
- Rounds total: 8
- Last floor: green (2026-10-11, round 8 after: vitest 1773, swift test 1192, PR CI on 694d806)
- Updated: 2026-10-12, round 8 done; the goal waits for the human's merge of PR #190

## Queue

None.

## Failures

None.

## Proposals waiting on the human

None. 2026-10-09: the human chose the base-day rule (seven days, each
at least 25% of the median daily spend).

## Done

- `all-range`, round 8, PR #190. See `rounds/008.md`. The range
  toggle gains `all`, and every figure follows it.
- `legend-and-range`, round 7, PR #190. See `rounds/007.md`. A legend
  row, charts that follow the range, and UNIT COSTS on a log axis.
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

The human merges PR #190. Then the foreman releases and upgrades.
