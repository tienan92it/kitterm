# ADR 0003: The input route refuses a large body to a cooked reader

## Status

Accepted (2026-09-07).

## Context

`POST /api/sessions/<id>/input` types a body into a session's terminal.
Since PR #65 a program in the foreground gets the body in pieces of 512
bytes, 50ms apart, because Claude Code keeps only the last read of a fast
paste. That pacing works for a reader in raw mode, and 16 KiB reached
Claude Code whole.

The pacing does nothing for a reader in canonical (cooked) mode. The
kernel then holds a line until its newline, and it caps the line. We
measured the cap on 2026-09-07 with a `sleep` in the foreground of a pty
and one write to the master:

| Platform | One line of | Reader received |
|----------|-------------|-----------------|
| Darwin 25.6 | 2051 bytes | Nothing. The queue kept 1024 bytes (`MAX_INPUT`), rang a bell for each byte after them, and dropped the newline, so no line ever completed. |
| Linux 6.8 (Alpine 3 container) | 5005 bytes | The first 4095 bytes and the newline. |
| Both | 901 bytes | The whole line. |

The bells are output: a pane shows 1024 `^G` and nothing else. A foreman
that typed a 2 KiB prompt at a program still starting sees the program
come up with a 1 KiB head in its input and no error anywhere. The daemon
cannot see the loss either: the master accepted every byte.

Cooked readers a foreman meets: a `sleep`, a program between its spawn
and its first `tcsetattr` (Claude Code takes about a second), a shell
reading a here-doc, and a shell without a line editor at its prompt. An
interactive `claude`, `vim`, and a shell's line editor clear ICANON, and
the pacing covers them.

The daemon can read the mode. `tcgetattr` on the master reports the
slave's termios on Darwin and on Linux (measured in cooked mode, in raw
mode, and after the reader exited; Linux routes a master's `TCGETS` to
its link). The daemon closes the slave after spawn, so the master is the
only handle it holds, and it is enough.

Three guards were candidates.

1. **Refuse.** The daemon answers 409 with a JSON reason when the body
   exceeds the cap and the terminal is in canonical mode. A caller
   overrides the guard with a query flag.
2. **Wait, then refuse.** The daemon waits a bounded time for ICANON to
   clear before it types, and answers 409 when the time runs out.
3. **Document only.** The route types the body, and AGENTS.md and the
   foreman skill tell the caller to read the screen first.

Guard 2 hides latency in the route: a `sleep` never clears, and a
foreman that waits a second on every call cannot tell a slow program from
a cooked one. Guard 3 keeps the loss silent, and the foreman skill already
tells a foreman to read the screen before it types; the loss happened
anyway, because a screen does not show a termios flag.

## Decision

We use guard 1. The route refuses a body over
`PtySession.canonicalLineBytes` (1024 on Darwin, 4095 on Linux) while the
terminal is in canonical mode, unless the request carries `?force=1`.

- `PtySession.inputIsCanonical` reads ICANON with `tcgetattr` on the
  master at request time, like `foregroundProgram`. Nil when the pty is
  gone, and the guard then stands aside.
- The 409 body is `{"ok":false,"reason":"cooked","error":...,
  "foregroundProgram":<name or null>,"limit":<cap>,"bytes":<count>}`.
  The error text says what holds the terminal, what the kernel keeps,
  and what to do: read the screen, wait for the program to take raw
  mode, or force.
- The guard applies with and without `?enter=1`, and to a shell as much
  as a program. The termios flag is the fact; the reader's name is only
  the label in the message.
- The MCP `send_input` tool passes the 409 body through as its error
  text, as it does every non-2xx answer, and takes `force:true` for
  `?force=1`.

## Consequences

Good:

- A large prompt typed at a program still starting is refused in one
  round trip, with the program's name, instead of arriving cut with no
  error. The foreman reads the screen and sends it again.
- A short body into a cooked reader still types. A line under the cap
  arrives whole, and a here-doc or a `read` prompt keeps working.
- The check is one `tcgetattr`, once per request, on the request path
  only. The output path is unchanged.
- A caller that knows its reader keeps every byte of control: `?force=1`
  types the body as before.

Bad, and accepted:

- The guard is a size and a flag, not proof of loss. A cooked reader that
  reads lines as they arrive, such as a shell fed a multi-line script,
  takes a body over the cap whole when every line is under it. That
  caller passes `?force=1`, or sends the body in requests under the cap.
- A body over the cap with newlines every 1024 bytes is refused on Darwin
  although the kernel might keep it. We refuse it because the master
  blocks at 1022 queued bytes once a line completes, and the outcome then
  depends on when the reader wakes.
- The cap is a platform constant, not a read of the kernel's value.
  `MAX_INPUT` and `N_TTY_BUF_SIZE` have held for decades.

Closed:

- Guard 2. A change that makes the route wait for ICANON reverses this
  record. A foreman that wants to wait calls `read_screen` or
  `wait_for_events` and sends again.
- Guard 3. A change that removes the 409 and keeps only the docs reverses
  this record.
- Splitting the body into lines under the cap inside the daemon. A split
  prompt is two pastes to Claude Code, which was the loss PR #65 removed.
