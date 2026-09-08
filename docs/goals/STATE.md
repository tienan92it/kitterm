# STATE: projects-and-knowledge

- Status: active
- Round: 1 of 3 in this budget
- Rounds total: 1
- Last floor: green (2026-09-08, round 1 after)
- Updated: 2026-09-08

## Queue

1. `project-identity` (capability 1): round 1 open, commit `f1f6cc9` on
   `goals/project-identity`, one correction pending after the human answers
   the pin question.
2. `dashboard` (capability 2)
3. `scaffold-and-docs` (capability 3)
4. `goal-loop-skill` (capability 4)
5. `knowledge-on-dashboard` (capability 5)
6. `dogfood` (capability 6)

## Failures

None. One pre-existing flake recorded in `rounds/001.md` (runtime
candidate, `LiveTakeoverTests`).

## Proposals waiting on the human

- `Tests/KittermCLITests/MCPToolsTests.swift:18`: change the tool-count pin
  from 15 to 16 so `list_projects` is advertised. See `rounds/001.md`.
- `LOOP.md` Authority: a count pin or a golden list in an existing test is
  Propose, not Frozen, when the change adds and removes nothing.
- Watch-grade access to `GET /api/projects/<id>/knowledge/<path>`. The plan
  recommends readable, the same class as a cwd. Decide before round 5.

## Next action

Wait for the human's answer on the pin. On "change the pin": send the crew
session `84633C2C` the correction (change the pin, add the schema entry and
the golden test, run the floor, commit, post a note), verify, archive the
session, close round 1 as done. On "keep unadvertised": close round 1 as
done with the tool unadvertised and open a queue item for it. Then round 2:
`dashboard`, branch off `goals/project-identity`.
