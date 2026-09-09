# Request 04: two goals in one package

Approved 2026-09-09. Frozen.

## Fixture

`~/.kitterm/projects.json` registers this checkout. `docs/goals/` holds
`LOOP.md`, `facts.md`, `projects-and-knowledge/` with `Status: done` and
eight records, and `goal-folders/` with `Status: active`. One crew
session runs in this checkout with labels `goal:goal-folders`, `round:1`.

## Request

Open `/sessions`. Run `kitterm goal list <this checkout>`. Run
`kitterm goal new <a temp checkout> demo`.

## Expected behaviour

- The `kitterm` card shows `goal-folders` expanded: its title, `round 1 of
  3`, `active`, the next action, a proposals link, and a record link that
  opens `goal-folders/rounds/001.md` as a text page once it exists; and
  `projects-and-knowledge` as one line, `done`, with a link to its latest
  record `projects-and-knowledge/rounds/008.md`.
- The crew session appears under a `goal: goal-folders` sub-header with a
  `round 1` chip.
- `GET /api/projects/kitterm/knowledge` answers `goals` with two entries,
  `goal-folders` first.
- `kitterm goal list` prints two lines, slug and status each.
- `kitterm goal new` writes `docs/goals/demo/` with five entries and
  refuses a second run with nothing written.

## Expected persistent effects

None on this checkout beyond the temp checkout's new folder.
