# STATE: sessions-workflow

- Status: active
- Round: 2 of 3 in this budget (second budget)
- Rounds total: 5
- Last floor: green (2026-10-05, round 5 after: vitest 1548, PR CI on fd1fa64)
- Updated: 2026-10-05, direction check: the human added the branch reader, dropped `list_pulls`, and set a second budget of 3

## Queue

1. `stage-tree` (capability 5), PR #185.

## Failures

None.

## Proposals waiting on the human

- `plan.md` row 2: add `isCrossRepository` to the `gh` field list.
  Round 4 needed it to skip fork pull requests (Chartered by row 3b).
  See `rounds/004.md`.

## Done

- `line-stage`, round 5, PR #185. See `rounds/005.md`. A pure
  `sessions-stage.ts` decides each line's stage, the pull request words
  and the `REVIEW` line.
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

Round 6: `stage-tree` from `plan.md` row 5; proof: the design
foundation's proofs and completion conditions 1, 4, 6 and 7.
