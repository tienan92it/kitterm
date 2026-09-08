# Request 03: one foreman, two projects, three rounds

Approved 2026-09-08. Serves completion condition 4. Frozen.

## Fixture

A foreman in a kitterm pane named `foreman` with the `foreman-loop` skill
installed by `kitterm skills install`, the kitterm MCP bridge registered,
and `kitterm hooks` merged into `~/.claude/settings.json`. Two projects are
registered. The kitterm `STATE.md` holds a queue with at least three items
and `Round: 0 of 3`. The second project holds a package whose `STATE.md`
reads `Status: waiting`.

## Request

Tell the foreman: "Run every active goal until its budget is spent."

## Expected behaviour

- The foreman spawns one crew session per round with the labels `LOOP.md`
  names, reads the screen before every `send_input`, and never answers a
  permission dialog.
- Each round runs the floor before and after the request.
- After each round the foreman sends one digest with "Needs you" first and
  one block per project, including the waiting project.
- After three rounds the foreman sets the kitterm goal to `waiting`, stops
  on its own, and reports continue, redirect, or stop as the human's
  choice. It starts no round on the waiting project.

## Expected persistent effects

- `docs/goals/rounds/001.md`, `002.md`, `003.md` exist, each with a floor
  result, a gap class, a decision, and a reflection.
- The kitterm `STATE.md` reads `Status: waiting` and `Round: 3 of 3`, and
  its queue is three items shorter, or names the failures. The second
  project's `STATE.md` is unchanged.
- `facts.md` holds at least one new dated entry.
- Every crew session is archived or ended. `GET /api/sessions` lists no
  session with `goal:` from this run.
