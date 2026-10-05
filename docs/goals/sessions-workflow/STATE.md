# STATE: sessions-workflow

- Status: waiting
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-10-05, round 3 after: swift test 1100, PR CI on 2411fc0)
- Updated: 2026-10-05, the budget is spent: direction check

## Queue

1. `line-stage` (capability 4)
2. `stage-tree` (capability 5)

## Failures

None.

## Proposals waiting on the human

- An MCP tool `list_pulls {project}` for `GET /api/projects/<id>/pulls`.
  It changes `MCPToolsTests`, which pins 16 tools and is frozen. See
  `rounds/002.md`.
- Read open goal branches: the knowledge summary also reads
  `docs/goals/<slug>/` from `origin/goal/<slug>` for every open pull
  request on that branch (and `origin/chore/<slug>` for its chore
  file), and keeps a goal folder that only the working tree holds, so a
  goal shows from its first round, not after its merge. A new row before
  capability 4 in `plan.md`. See `rounds/003.md`.

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

Direction check: the human decides the two proposals and a new budget.
Then round 4: `line-stage`, or the goal-branch reader first if the human
adds it.
