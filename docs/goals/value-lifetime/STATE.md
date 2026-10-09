# STATE: value-lifetime

- Status: done
- Round: 2 of 3 in this budget (second budget)
- Rounds total: 5
- Last floor: green (2026-10-09, round 5 after: vitest 1724, PR CI on 7a3deb1)
- Updated: 2026-10-09, the goal is done; PR #188 is ready

## Queue

None.

## Failures

None.

## Proposals waiting on the human

None. 2026-10-09: the human chose the base-day rule (seven days, each
at least 25% of the median daily spend).

## Done

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

The human merges PR #188; the foreman releases and upgrades, and checks
the charts on the live page.
