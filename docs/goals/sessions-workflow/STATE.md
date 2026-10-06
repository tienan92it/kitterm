# STATE: sessions-workflow

- Status: active
- Round: 0 of 1 in this budget (resumed on the human's word)
- Rounds total: 6
- Last floor: green (2026-10-06, CI on `main` at 8a2dcb1)
- Updated: 2026-10-06, resumed for one round: the REVIEW rows (`corpus/02-review-rows.md`)

## Queue

1. `review-rows` (`corpus/02-review-rows.md`), PR #186.

## Failures

None.

## Proposals waiting on the human

- `plan.md` row 2: add `isCrossRepository` to the `gh` field list.
  Round 4 needed it to skip fork pull requests (Chartered by row 3b).
  See `rounds/004.md`.

## Done

- `stage-tree`, round 6, PR #185. See `rounds/006.md`. The SESSIONS
  tree prints each line's stage, the PR state and the `REVIEW` line, as
  the approved frames show.
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

Round 7: `review-rows`; proof: vitests, screenshots at 1200 and 390,
and the redrawn REVIEW frames in `design/sessions.pen`.
