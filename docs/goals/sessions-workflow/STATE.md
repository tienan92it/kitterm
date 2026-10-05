# STATE: sessions-workflow

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-10-05, round 1 after: vitest 1487, no code change)
- Updated: 2026-10-05

## Queue

1. `pull-request-state` (capability 2), PR #185.
2. `merged-base-branch` (capability 3)
3. `line-stage` (capability 4)
4. `stage-tree` (capability 5)

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `sessions-design`, round 1, PR #185. See `rounds/001.md`. The human
  approved the three frames of `design/sessions.pen` at `2762a02`
  (`corpus/01-approved-design.md`).

## Next action

Round 2: `pull-request-state` from `plan.md` row 2; proof: new tests with
a fake `gh` on `PATH`.
