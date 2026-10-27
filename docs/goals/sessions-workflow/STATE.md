# STATE: sessions-workflow

- Status: done
- Round: 1 of 1 in this budget (resumed on the human's word, a fourth time)
- Rounds total: 9
- Last floor: green (2026-10-27, round 9 after: swift test 1379, PR CI on 3ade55b)
- Updated: 2026-10-27, round 9 done: a free change probe

## Queue

None.

## Failures

None.

## Proposals waiting on the human

- `plan.md` row 2: add `isCrossRepository` to the `gh` field list.
  Round 4 needed it to skip fork pull requests (Chartered by row 3b).
  See `rounds/004.md`.

## Done

- `change-probe`, round 9, PR #205. See `rounds/009.md`. A conditional
  probe every 5 s per watched repository; a change reaches the page in
  1 to 11 s.
- `faster-pull-sync`, round 8, PR #196. See `rounds/008.md`. A change
  from a command reaches the page in about 2 s.
- `review-rows`, round 7, PR #186. See `rounds/007.md`. REVIEW is a
  header with the counts and one row per ready pull request, with the
  drafts folded.
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

None. The goal is done. A later change to the REVIEW section resumes it
for one round.
