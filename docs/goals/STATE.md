# STATE: projects-and-knowledge

- Status: active
- Round: 2 of 3 in this budget (rounds 1 and 2 done)
- Rounds total: 2
- Last floor: green (2026-09-08, round 2 after)
- Updated: 2026-09-08

## Queue

1. `scaffold-and-docs` (capability 3), branch off `goals/dashboard`
2. `goal-loop-skill` (capability 4)
3. `knowledge-on-dashboard` (capability 5)
4. `dogfood` (capability 6)

## Failures

None. One pre-existing flake recorded in `rounds/001.md` (runtime
candidate, `LiveTakeoverTests`).

## Proposals waiting on the human

- `plan.md` capability 1, the resolution rule: let the nearest `.git` win
  over a registered parent prefix. See `rounds/002.md`. Decide before the
  capability 1 PR merges.
- `LOOP.md` Authority: a count pin or a golden list in an existing test is
  Propose, not Frozen, when the change adds and removes nothing.
- Watch-grade access to `GET /api/projects/<id>/knowledge/<path>`. The plan
  recommends readable, the same class as a cwd. Decide before round 5.

## Done

- `project-identity` (capability 1): round 1, `goals/project-identity` at
  `9bb6d8b`, not pushed. See `rounds/001.md`.
- `dashboard` (capability 2): round 2, `goals/dashboard` at `b7bd5a6`, not
  pushed. See `rounds/002.md`.

## Next action

Round 3, the last in this budget: `scaffold-and-docs`. Spawn one crew
session in the repository root with labels `crew:projects-and-knowledge`,
`goal:projects-and-knowledge`, `round:3`, `task:scaffold-and-docs`. Branch
`goals/scaffold-and-docs` off `goals/dashboard`. Run the floor. Send the
capability 3 row from `plan.md`: `kitterm project init <path>`, the 15-tool
table in `docs/foreman.md`, the state tree in `docs/architecture.md`. After
round 3 set `Status: waiting` and report for the direction decision.
