# STATE: sessions-workflow

- Status: active
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-10-05, round 2 after: swift test 1055, PR CI on 5af2ff8)
- Updated: 2026-10-05

## Queue

1. `merged-base-branch` (capability 3), PR #185.
2. `line-stage` (capability 4)
3. `stage-tree` (capability 5)

## Failures

None.

## Proposals waiting on the human

- An MCP tool `list_pulls {project}` for `GET /api/projects/<id>/pulls`.
  It changes `MCPToolsTests`, which pins 16 tools and is frozen. See
  `rounds/002.md`.

## Done

- `pull-request-state`, round 2, PR #185. See `rounds/002.md`.
  `GET /api/projects/<id>/pulls` answers each GitHub project's pull
  requests from `gh`, read once a minute off the event loop.
- `sessions-design`, round 1, PR #185. See `rounds/001.md`. The human
  approved the three frames of `design/sessions.pen` at `2762a02`
  (`corpus/01-approved-design.md`).

## Next action

Round 3: `merged-base-branch` from `plan.md` row 3; proof: new tests
against a scratch bare repository.
