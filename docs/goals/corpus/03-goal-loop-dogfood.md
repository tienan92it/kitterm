# Request 03: three rounds through the goal loop

Approved 2026-09-08. Serves completion condition 4. Frozen.

## Fixture

A foreman in a kitterm pane with the `goal-loop` skill installed by
`kitterm skills install`, the kitterm MCP bridge registered, and
`kitterm hooks` merged into `~/.claude/settings.json`. `STATE.md` holds a
queue with at least three items and `Round: 0 of 3`.

## Request

Tell the foreman: "Run the goal loop until the budget is spent."

## Expected behaviour

- The foreman spawns one crew session per round with the labels `LOOP.md`
  names, reads the screen before every `send_input`, and never answers a
  permission dialog.
- Each round runs the floor before and after the request.
- After three rounds the foreman stops on its own and reports continue,
  redirect, or stop as the human's choice.

## Expected persistent effects

- `docs/goals/rounds/001.md`, `002.md`, `003.md` exist, each with a floor
  result, a gap class, a decision, and a reflection.
- `STATE.md` reads `Round: 3 of 3` and its queue is three items shorter, or
  names the failures.
- `facts.md` holds at least one new dated entry.
- Every crew session is archived or ended. `GET /api/sessions` lists no
  session with `goal:` from this run.
