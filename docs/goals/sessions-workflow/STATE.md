# STATE: sessions-workflow

- Status: active
- Round: 1 of 3 in this budget (second budget)
- Rounds total: 4
- Last floor: green (2026-10-05, round 4 after: swift test 1141, PR CI on 9d6b235)
- Updated: 2026-10-05, direction check: the human added the branch reader, dropped `list_pulls`, and set a second budget of 3

## Queue

1. `line-stage` (capability 4), PR #185.
2. `stage-tree` (capability 5)

## Failures

None.

## Proposals waiting on the human

- `plan.md` row 2: add `isCrossRepository` to the `gh` field list.
  Round 4 needed it to skip fork pull requests (Chartered by row 3b).
  See `rounds/004.md`.

## Done

- `goal-branch-reader`, round 4, PR #185. See `rounds/004.md`. A goal
  shows from its open goal branch before it merges, and a goal folder
  only the working tree holds is kept.
- `merged-base-branch`, round 3, PR #185. See `rounds/003.md`. The
  knowledge routes read `origin/<base>` through git objects after a
  fetch each minute, so a merge shows with no `git pull`.
- `pull-request-state`, round 2, PR #185. See `rounds/002.md`.
  `GET /api/projects/<id>/pulls` answers each GitHub project's pull
  requests from `gh`, read once a minute off the event loop.
- `sessions-design`, round 1, PR #185. See `rounds/001.md`. The human
  approved the three frames of `design/sessions.pen` at `2762a02`
  (`corpus/01-approved-design.md`).

## Next action

Round 5: `line-stage` from `plan.md` row 4; proof: a vitest with one
case per row of the stage table and per level.
