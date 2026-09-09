# Request 01: the phone dashboard

Approved 2026-09-08. Serves completion condition 1. Frozen.

## Fixture

A daemon started with `--agent-control --retain-logs`. Three sessions:

1. A crew session spawned by `POST /api/sessions` in
   `/Users/antran/Workspace/kitterm` with labels `crew:demo`, `task:one`,
   running `claude` on a turn that ends in a permission dialog.
2. A human pane in `/Users/antran/Workspace` whose last command exited 130.
3. A human pane in `/Users/antran/Workspace/kitterm` at its prompt.

## Request

Open `/sessions` in a browser at 390 px width.

## Expected behaviour

- The attention strip lists the pending approval and the failed pane, in
  that order, before any project card.
- One card reads `kitterm` and holds sessions 1 and 3. Session 1 sits under
  a `crew: demo` sub-header. Session 2 sits under a card for `Workspace`.
- Allow on the approval strip entry runs the tool in session 1 and the
  entry leaves the strip within one poll.
- Archive on session 2 asks once, then the row moves under the card's
  archived list and `GET /api/archives` lists it.
- Kill on session 3 asks once, then the row is gone and
  `GET /api/sessions` no longer lists it.

## Expected persistent effects

- `~/.kitterm/archive/<id-of-session-2>/archive.json` exists.
- No horizontal scroll at 390 px.
