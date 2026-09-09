# Request 02: the project card reads STATE.md

Approved 2026-09-08. Serves completion condition 2. Frozen.

## Fixture

`~/.kitterm/projects.json` registers `/Users/antran/Workspace/kitterm` with
`knowledge: "docs/goals"`. `docs/goals/STATE.md` in that checkout reads
`Round: 2 of 3`, and its `## Next action` section starts with the line
`Round 3: dashboard.` One crew session runs in that checkout with labels
`goal:projects-and-knowledge`, `round:2`.

## Request

Open `/sessions`.

## Expected behaviour

- The `kitterm` card shows the goal title from `goal.md`, the text
  `round 2 of 3`, and the next action line.
- The crew session appears under a `goal: projects-and-knowledge` sub-header
  inside the card with a `round 2` chip.
- The card links to `docs/goals/rounds/002.md` through the knowledge route.
- `GET /api/projects/<id>/knowledge/../../Package.swift` answers 400.
- `GET /api/projects/<id>/knowledge/STATE.md` from a watch token answers
  as the accepted decision in `STATE.md` says.

## Expected persistent effects

None. The route is read-only. `git status` in the checkout is unchanged.
