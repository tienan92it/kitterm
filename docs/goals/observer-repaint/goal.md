# Goal: A client that joins a running session sees a correct screen, not a garbled replay

## Objective

A human opens a running session from the fleet view ("Open the pane") or
reattaches after a reload. The pane must show the foreground program's
current screen, fully painted. Today a session that runs a full-screen
program (`claude`, `vim`, lazygit) replays a raw byte tail from the ring
into xterm.js. The tail starts mid-frame and omits the alternate-screen
switch, so the pane shows garbled output until the program next repaints.
An idle `claude` never repaints, so the garble stays. After this goal the
join shows a coherent screen with no keystroke from the human.

## Exclusions

- The daemon does not become a terminal emulator on the output path. No
  per-client screen grid, no cursor model, and no CSI/SGR interpreter in
  the hot path. Screen state stays the client's business (`AGENTS.md`).
- This goal does not add a screen grid to `KittermDaemon`. `KittermScreen`
  stays in the CLI only (ADR 0001).
- It does not touch the `/edit`, `/md`, or `/sessions` pages.

## Completion condition

All hold on a build from `main`:

1. A client that joins a session which runs `claude` on the alternate
   screen, idle at a prompt, shows the prompt and the last painted frame,
   not raw escape bytes, with no keystroke.
2. A second client attaching does not corrupt the controller's screen.
3. A join to a session on the normal screen (a shell with scrollback) still
   shows the scrollback tail, as today.

The floor (`swift test`, `pnpm build`, `pnpm test`, and `KittermBench`
TUI-redraw within its noise floor) is green at every step.
