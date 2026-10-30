# 6. Repaint on attach with a SIGWINCH nudge

Date: 2026-10-30

## Status

Accepted

## Context

A client that joins a running session sees a garbled screen when a
full-screen program holds the terminal. The fleet view's "Open the pane"
link and a reload both attach to the live session and replay the ring's
tail into xterm.js. The tail is raw bytes: it can start mid-frame, and the
alternate-screen switch (`ESC[?1049h`) that a program like `claude`, `vim`
or lazygit sent on start has long rotated out of the 4 MiB ring for any
long-running session. xterm then paints the bytes on the wrong buffer, and
an idle program never repaints by itself, so the garble stays until the
human types.

The daemon does not emulate a terminal (ADR 0001): it holds no screen grid
and no cursor, so it cannot reconstruct the screen to replay a coherent
frame. Two mechanisms were weighed:

- **Replay from the last alternate-screen switch.** Scan the ring back to
  the last `ESC[?1049h` or full clear and replay from there. It has no
  effect on the controller, but it fails exactly when the bug is worst: the
  switch is out of the ring for a long-running session, so there is nothing
  coherent to replay, and it needs a fallback.
- **A SIGWINCH nudge.** On attach, change the PTY window size and restore
  it. The kernel sends `SIGWINCH` to the foreground group, and the program
  repaints its full current screen. It works regardless of ring age, which
  is the common case.

## Decision

On a new attach to a live session the daemon nudges the PTY window size and
restores it, so the foreground program repaints itself.
`PtySession.nudgeWindowSize()` writes the size one row short through the
same `TIOCSWINSZ` path as a resize, then restores the held size on the
event loop after `windowNudgeRestoreDelay` (50 ms). The two writes must not
coalesce: two `TIOCSWINSZ` with no pause between them become one `SIGWINCH`
that reports the old size and repaints nothing (measured 2026-10-30; 2 ms
and up repaints each time). The restore re-applies whatever size the
session holds then, so the held size, the observers' resize frames and the
recorder never see the transient row, and a resize that lands between the
two writes wins.

The nudge runs only when the foreground is not the shell
(`foregroundIsShell`): a shell at its prompt needs no repaint and its
replay already holds the scrollback. `WebSocketSessionHandler` calls it
after the replay is queued, in `adoptAsObserver` and in `wire` for an
adopted live session, never for a fresh shell and never in
`promoteToController` (that client saw every byte live).

## Consequences

- A client that joins a running `claude`, `vim` or lazygit sees the real
  screen with no keystroke, whatever the age of the session.
- The controller's screen reflows briefly each time a client joins, because
  the PTY size is shared. This is the accepted cost.
- The daemon gains no screen model; the program does the repaint. ADR 0001
  stands.
- The mechanism relies on the program handling `SIGWINCH`. A program that
  ignores it (rare for a full-screen program) is not repainted; its join is
  no worse than before.
- A shell at its prompt and a session on the normal screen are untouched:
  the gate skips them, and their scrollback replay is unchanged.
