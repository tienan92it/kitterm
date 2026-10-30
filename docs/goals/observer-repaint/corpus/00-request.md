# Request: a client that joins a running session sees a correct screen

Approved 2026-10-30 by the human, from a bug report in real use.

## The bug

A human opens a running session from the fleet view ("Open the pane",
`/?session=<id>`) or reattaches after a reload. The pane shows a garbled
screen. The session runs a full-screen program (`claude`, `vim`, lazygit)
on the alternate screen. The daemon replays a raw byte tail from the 4 MiB
ring into xterm.js; the tail starts mid-frame and the alternate-screen
switch is long out of the ring, so xterm paints garbage. An idle `claude`
never repaints, so the garble stays until the human types.

## The decision

The mechanism is the **`SIGWINCH` nudge**, chosen over a
replay-from-alt-screen-enter because the enter-alt-screen sequence has
rotated out of the ring for any long-running session — the common case —
and a replay cannot reconstruct the screen there. On a new attach the
daemon changes the PTY window size and restores it, so the foreground
program repaints its full current screen. The cost the human accepts: a
brief reflow on the controller's screen each time a client joins.

Record the decision in an ADR under `docs/adr/` (the next number is 0006).

## What the goal must prove

The completion condition in `goal.md`, unchanged:

1. A client that joins a session running `claude` on the alternate screen,
   idle at a prompt, shows the prompt and the last painted frame, not raw
   escape bytes, with no keystroke.
2. A second client attaching does not corrupt the controller's screen.
3. A join to a session on the normal screen (a shell with scrollback) still
   shows the scrollback tail, as today.

The daemon does not gain a screen model (ADR 0001 stands): the nudge makes
the program repaint itself; the daemon reads no grid.
