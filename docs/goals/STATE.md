# STATE: projects-and-knowledge

- Status: waiting
- Round: 3 of 3 in this budget (budget spent)
- Rounds total: 3
- Last floor: green (2026-09-08, round 3 after)
- Updated: 2026-09-08

## Queue

1. `goal-loop-skill` (capability 4), branch off `goals/scaffold-and-docs`
2. `knowledge-on-dashboard` (capability 5)
3. `dogfood` (capability 6)

## Failures

None. One pre-existing flake recorded in `rounds/001.md` (runtime
candidate, `LiveTakeoverTests`).

## Proposals waiting on the human

- `plan.md` capability 1, the resolution rule: let the nearest `.git` win
  over a registered parent prefix. See `rounds/002.md`. Decide before the
  capability 1 PR merges.
- `plan.md` capability 3: "names all 15 tools" becomes "16". See
  `rounds/003.md`.
- `LOOP.md` Authority: a count pin or a golden list in an existing test is
  Propose, not Frozen, when the change adds and removes nothing. See
  `rounds/001.md`.
- `plan.md`: add a corpus request for capabilities 3 and 4 before the next
  budget. See `rounds/003.md`.
- Watch-grade access to `GET /api/projects/<id>/knowledge/<path>`. The plan
  recommends readable, the same class as a cwd. Decide before capability 5.

## Done

- `project-identity` (capability 1): round 1, `goals/project-identity` at
  `9bb6d8b`, not pushed. See `rounds/001.md`.
- `dashboard` (capability 2): round 2, `goals/dashboard` at `b7bd5a6`, not
  pushed. See `rounds/002.md`.
- `scaffold-and-docs` (capability 3): round 3, `goals/scaffold-and-docs`
  at `332e096`, not pushed. See `rounds/003.md`.

## Next action

Direction decision by the human: continue, redirect, or stop. On
"continue": set `Status: active`, `Round: 0 of 3`, and start round 4 with
`goal-loop-skill` off `goals/scaffold-and-docs`. The branches stack:
`goals/knowledge-base`, `goals/project-identity`, `goals/dashboard`,
`goals/scaffold-and-docs`. Push and open the PRs in that order when the
human says so.
