# ADR 0004: The foreground program is named by its argv[0]

## Status

Accepted (2026-09-07).

## Context

PR #63 put `foregroundProgram` on the session row: the executable basename
of the process group leader that holds the terminal, from `tcgetpgrp` on
the master and `proc_pidpath` (Darwin) or `/proc/<pid>/exe` (Linux). A
foreman and the fleet view use the name to tell a crew session whose agent
still runs from one whose agent has quit.

For a pane that runs Claude Code the row read `2.1.263`. `~/.local/bin/claude`
is a launcher: it execs `~/.local/share/claude/versions/2.1.263`, a binary
named after its version, and keeps its pid and its argv. We measured the
leader of such a pane on 2026-09-07 (Darwin 25.6, Claude Code 2.1.263):

| Kernel field | Value |
|--------------|-------|
| `proc_pidpath` | `.../versions/2.1.263` |
| `PROC_PIDTBSDINFO` `pbi_comm` | `2.1.263` |
| `PROC_PIDTBSDINFO` `pbi_name` | `2.1.263` |
| `KERN_PROCARGS2` `argv[0]` | `claude` |
| Parent | the pane's `zsh`, in its own process group |

`pbi_comm` and `pbi_name` follow the exec path, so they carry the version
too. Linux behaves the same: `/proc/<pid>/comm` and `exe` follow the exec,
and `/proc/<pid>/cmdline` keeps the argv.

Three rules were candidates.

1. **Walk the parents.** Prefer the first ancestor in the same process
   group whose name is not version-like. The launcher execs, so the leader
   has no such ancestor: its parent is the shell. The rule also needs a
   definition of "version-like", which is a table in another form.
2. **Read argv[0].** Take the last path component of the leader's
   `argv[0]`, less a login shell's leading `-`. `KERN_PROCARGS2` on Darwin
   and `/proc/<pid>/cmdline` on Linux both hold the live argv.
3. **An alias table.** Map `2.1.263` to `claude`. The table needs an entry
   for every launcher and every version scheme, and goes stale.

## Decision

We use rule 2. `PtySession.invocationName(ofPID:)` reads the leader's
`argv[0]`, and `foregroundLeader` uses it as the name. The executable
basename is the fallback when the argv is unreadable or empty.

- The read stays at request time, once per call, on the request path
  only. Nothing on the output path asks.
- The shell check is unchanged: the name is compared with the spawned
  shell, the known-shell set, and the spawn helper. The helper's
  `argv[0]` is its path and the shell's is `-zsh`, so both still read as
  the shell.
- The name is what `ps` shows in its command column. A program that
  rewrote its argv (Claude Code's spare workers read `claude bg-spare`)
  reads as that title.

## Consequences

Good:

- A pane that runs Claude Code reads `claude` on the row, in
  `session.lingered`, and in the 409 body of the input route, on Darwin
  and on Linux, with no table.
- A launcher that forwards its argv, a symlink under another name, and
  `exec claude` all read as the name the user typed.
- The existing foreground tests hold: `cat` is `cat`, and the shell at
  its prompt is nil.

Bad, and accepted:

- A launcher that execs the target by path, as a `#!/bin/sh` script with
  a plain `exec` does, sets `argv[0]` to that path and still reads as the
  version. The Claude Code launcher forwards its argv.
- A program that sets its own title reads as the title, not the file. The
  fleet row and `ps` then agree.
- Two reads instead of one when the argv is unreadable: the argv, then the
  executable path. Both are microseconds.

Closed:

- Rule 1. A change that walks the process tree for the name reverses this
  record.
- Rule 3. A change that adds an alias table reverses this record.
