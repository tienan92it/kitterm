# ADR 0002: The linger clock reaps an idle shell, not a working session

## Status

Accepted (2026-09-05).

## Context

A program creates a crew session through `POST /api/sessions`. The registry
marks it orchestrated and arms a linger clock at spawn
(`orchestratedSessionLingerSeconds`, 3600 seconds, `--session-linger` to
change). The clock is cancelled when a client attaches and re-armed when the
last client leaves. When the clock fires with no client attached, the
registry reaps the session: it terminates the shell and discards its
records.

The clock has two jobs.

- A node whose shell crashed or exited stays inspectable for the window, so
  a foreman can read its commands and its output after the fact.
- A shell that nobody uses is dropped, so a crashed or restarted foreman
  cannot leak a session slot for the life of the daemon. The registry admits
  at most `maxConcurrentSessions` (64) sessions.

The clock had a third effect that nobody wanted. A foreman verified it on
2026-09-05. On 2026-09-04 at 18:11 it spawned three crew sessions with
labels and an `input` of `claude`. No browser ever attached to them, so the
clock armed at spawn ran to its end. The next morning two of the three were
gone. One had been idle at its Claude Code prompt with a finished PR. The
other had been mid-rebase with a live `claude` process. The foreman learned
of the loss from a `no such session` answer and had to respawn each one with
`claude --resume`.

The registry could not tell these sessions from an abandoned shell. It
looked at one thing: whether a client was attached. A foreman is not a
client. It reads a session through the HTTP API and the event feed, and it
never opens a socket to the pane. Every crew session therefore looks
detached for its whole life, and the clock reaps it on schedule while it
works.

The daemon already holds two signals that separate a working session from
an abandoned shell.

- `PtySession.foregroundIsShell` (PR #59) asks the tty which process group
  holds the terminal and names its leader. A `claude`, a `vim`, a rebase's
  editor, or a `sleep` in the foreground means a program has the terminal.
- `PtySession.lastOutputAt` records when output last arrived. A background
  job, a long build, or a redrawn prompt all move it.

Two rules were candidates.

1. **Never reap a live orchestrated session.** Arm the clock only from
   `sessionDidExit`. A session with a live shell is held for the life of
   the daemon, and only the foreman's `kill_session` or `DELETE
   /api/sessions/<id>` ends it.
2. **Re-arm the clock while the session works.** At the end of a window,
   reap the session only when the shell holds the terminal and no output
   arrived during the window. Otherwise start a new window and check again.

Rule 1 is simpler. It also removes the second job of the clock. A foreman
that crashes after `spawn_session` leaves a bare shell at its prompt, and a
foreman that crash-loops leaves one per attempt. With rule 1 those shells
hold their slots until the daemon restarts, and `--session-linger` no
longer bounds anything but an exited session's records.

## Decision

We use rule 2. The registry re-arms the linger clock while an orchestrated
session works, and reaps it only when it is idle.

The check runs when the clock fires, in `SessionRegistry.lingerExpired`,
once per window per session. It does not run on the output path. The
verdict at the end of a window is:

- The shell has exited: reap, whatever else is true. The records were
  readable for one full window.
- A client is attached or observing: keep. The clock should not have fired.
- The session is a browser tab's (no labels, not spawned by the API): reap.
  A closed tab keeps its 300 second window and today's rule.
- The session is orchestrated and a program other than the shell holds the
  terminal: re-arm the full window.
- The session is orchestrated and output arrived since the clock was armed:
  re-arm the full window.
- Otherwise the session is an orchestrated shell at its prompt that printed
  nothing for a whole window: reap.

An agent's hook report (`POST /api/hooks`) is not a third signal. A hook
fires only from a running agent, and a running agent already holds the
terminal, so the foreground check covers it.

The window that a re-arm starts is a full window, not the remainder. The
suspending clock keeps a machine's sleep from consuming a window, and a
remainder computed from wall-clock dates would give that back.

## Consequences

Good:

- A crew session at its Claude Code prompt, or waiting on a human for a
  day, is never reaped by the clock. The foreman ends it with
  `kill_session` when its work merges, which was already the loop's rule.
- An abandoned shell is still dropped. A shell that prints nothing and runs
  nothing for a whole window goes at the end of that window, so at most
  two windows after its last output.
- A crashed node is still inspectable for one window after its exit, and
  is still reaped after it.
- The output path is unchanged. The registry reads two fields once per hour
  per detached session. `foregroundIsShell` is one `tcgetpgrp` and one
  `proc_pidpath`.
- A browser tab's session behaves as before.

Bad, and accepted:

- A program a foreman forgot is held for the life of the daemon. A
  `claude` left at its prompt after its foreman died looks the same to the
  registry as one waiting on a human, and the registry must not guess. The
  bound is `maxConcurrentSessions`, and the remedy is `list_sessions` and
  `kill_session`, or `DELETE /api/sessions/<id>`. `--session-linger` and
  its 24 hour ceiling bound an idle shell and an exited session's records,
  and nothing else.
- The foreground check reads the tty. A pty whose foreground group cannot
  be named reads as the shell, so a session in that state is reaped on the
  output signal alone.
- A shell that a background job keeps printing to lives as long as the job
  prints. That is the point: the job is work.

Closed:

- Rule 1. A live orchestrated session is not exempt from the clock. A
  change that arms the clock only from `sessionDidExit` reverses this
  record.
- Re-arming from the output path. The check is lazy, at the deadline, and
  a change that hops to the actor on every read reverses the cost
  argument in ADR 0001's spirit: the loop stays cheap.
