# STATE: value-lifetime

- Status: active
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-10-09, round 2: no code; PR CI on 2dc446c)
- Updated: 2026-10-09, the human approved the design at 4b8379e

## Queue

1. `lifetime-series` (capability 3), PR #188.
2. `lifetime-chart` (capability 4)

## Failures

None.

## Proposals waiting on the human

- The base day rule: the first day of the first run of seven days that
  each have recorded spend (2026-09-03 on the real rollup). See
  `corpus/03-approved-design.md`.

## Done

- `lifetime-design`, round 2, PR #188. See `rounds/002.md`. The human
  approved TOTALS and UNIT COSTS at 4b8379e.
- `yield-per-day`, round 1, PR #188. See `rounds/001.md`.
  `GET /api/yield/daily` answers merged work per day.

## Next action

Round 3: `lifetime-series` from `plan.md` row 3; proof: a vitest on the
human's tables.
