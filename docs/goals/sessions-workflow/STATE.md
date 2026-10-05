# STATE: sessions-workflow

- Status: active
- Round: 0 of 3 in this budget (second budget)
- Rounds total: 3
- Last floor: green (2026-10-05, round 3 after: swift test 1100, PR CI on 2411fc0)
- Updated: 2026-10-05, direction check: the human added the branch reader, dropped `list_pulls`, and set a second budget of 3

## Queue

1. `goal-branch-reader` (capability 3b), PR #185.
2. `line-stage` (capability 4)
3. `stage-tree` (capability 5)

## Failures

None.

## Proposals waiting on the human

None. 2026-10-05: the human accepted the branch reader (`plan.md` row
3b) and declined `list_pulls`.

## Done

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

Round 4: `goal-branch-reader` from `plan.md` row 3b; proof: new tests
against a scratch bare repository.
