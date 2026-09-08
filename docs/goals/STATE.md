# STATE: projects-and-knowledge

- Status: active
- Round: 1 of 3 in this budget (round 1 done)
- Rounds total: 1
- Last floor: green (2026-09-08, round 1 after the correction)
- Updated: 2026-09-08

## Queue

1. `dashboard` (capability 2), branch off `goals/project-identity`
2. `scaffold-and-docs` (capability 3)
3. `goal-loop-skill` (capability 4)
4. `knowledge-on-dashboard` (capability 5)
5. `dogfood` (capability 6)

## Failures

None. One pre-existing flake recorded in `rounds/001.md` (runtime
candidate, `LiveTakeoverTests`).

## Proposals waiting on the human

- `LOOP.md` Authority: a count pin or a golden list in an existing test is
  Propose, not Frozen, when the change adds and removes nothing.
- Watch-grade access to `GET /api/projects/<id>/knowledge/<path>`. The plan
  recommends readable, the same class as a cwd. Decide before round 5.

## Done

- `project-identity` (capability 1): round 1, `goals/project-identity` at
  `9bb6d8b`, not pushed. See `rounds/001.md`.

## Next action

Round 2: `dashboard`. Spawn one crew session in the repository root with
labels `crew:projects-and-knowledge`, `goal:projects-and-knowledge`,
`round:2`, `task:dashboard`. Branch `goals/dashboard` off
`goals/project-identity`. Run the floor. Send the capability 2 row from
`plan.md` with the "Fleet view and session model" facts and corpus request
`01-phone-dashboard`. Ask the crew to run the `frontend-design` skill
before it rebuilds the rows.
