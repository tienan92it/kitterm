# Running a foreman with kitterm

This file holds the set-up, the MCP tools, the typed state, and the daemon's
behaviour on an upgrade and a restart. The goal loop that a foreman runs has
two other homes: `docs/goals/LOOP.md` holds its policy, from the roles to
the stop rules, and the skill `examples/foreman/foreman-loop.md` holds the
foreman's procedure. This file names a rule of those two in one sentence
and does not restate it.

A foreman is an agent that manages a crew of other agent sessions. It spawns a
session per task, watches each session's state, tells you when a session needs
you, passes your messages into a session, and ends a session when the work is
done. kitterm holds no foreman logic. kitterm ships the machinery — an HTTP
API, an MCP toolset, and the `/sessions` fleet view. The foreman is an ordinary
agent you run in a pane.

This split is deliberate. kitterm stays a fast, quiet terminal. Every crew
session works for a human even when no foreman runs. You start the foreman, or
you drive the crew yourself from the fleet view; the machinery is the same.

## Set up

You do three things once.

1. Start the daemon with agent control. The foreman spawns shells and types
   into them, so the daemon needs the write routes:

   ```
   kitterm start --agent-control --retain-logs
   ```

   `--retain-logs` keeps each session's output on disk past the 4 MiB memory
   ring, so a long crew run stays fully readable.

2. Give the foreman the MCP toolset. Register the bridge with your agent:

   ```
   claude mcp add kitterm -- kitterm mcp
   ```

   The bridge is a stdio MCP server. It proxies the daemon's HTTP API and holds
   no state.

3. Let a crew agent ask you for permission. Add the hook config so a
   permission dialog reaches the fleet view:

   ```
   kitterm hooks >> ~/.claude/settings.json
   ```

   Merge it by hand — `kitterm hooks` prints the block, it does not edit the
   file. The held event is `PermissionRequest`, which fires only when Claude
   would show you a dialog; an auto-allowed tool never touches the daemon, so
   the hooks are safe to install for every session. The daemon then holds that
   dialog until you allow or deny it from any device. No decision is an
   answer: on expiry the agent shows the dialog in its own pane.

   Two limits. A crew you run with `claude -p` never raises a dialog — print
   mode refuses a tool instead of asking — so give such a crew
   `--dangerously-skip-permissions` or `--allowedTools`. And a session whose
   `permissions.defaultMode` is `auto` never asks either; approvals only
   reach the fleet view from a session that would have asked you.

## The tools

The bridge gives the foreman these tools.

| Tool | Job |
|------|-----|
| `list_sessions` | Every crew session with its typed state, name, last command, and what holds its terminal. Filter by a label or by a project id (`project`). |
| `get_session` | One session's full status row. |
| `spawn_session` | Start a crew session. Name it; optionally set cwd, profile, labels, and an initial input line. |
| `rename_session` | Set a session's name, note, or labels. |
| `send_input` | Type into a session and press Enter — a message to its agent, an answer, or a command. Refuses a text over 1 KiB while a cooked reader holds the terminal; `force:true` overrides. Give `keys` to press a named key (`up`, `down`, `left`, `right`, `enter`, `escape`, `ctrl-c`): an escape byte does not survive an MCP client's JSON string argument, so `text` cannot carry an arrow key. |
| `list_commands` | The commands a session ran, with exit codes. |
| `wait_for_command` | Block until a command finishes, then read its exit code. |
| `read_output` | Read a command's captured output. |
| `read_screen` | Read what a pane shows, rendered at its real size. Use it before you type into a TUI. |
| `screen_state` | Name what a pane shows from rules over its screen: `prompt-empty`, `prompt-has-text`, `working`, `waiting-on-own-job`, `trust-dialog`, `permission-dialog`, `agent-exited`, or `unknown`, with the rule and the line that matched. No network call. `unknown` means: read the screen. |
| `wait_for_events` | Block until anything changes across the whole crew. |
| `post_note` | Post a status note onto the event feed. |
| `list_approvals` | The tool calls blocked waiting for a human. |
| `kill_session` | End a session and its shell. |
| `archive_session` | Save a finished session's commands, exit codes, and output to `~/.kitterm/archive/<id>/`, then end it. |
| `list_archives` | Every archived session: finished work whose evidence was kept. |
| `list_projects` | The identity of every project the daemon has seen, registered or discovered from a cwd, with its knowledge directory. |

There is no approve or deny tool on purpose. Deciding a permission prompt is
your privilege, not the foreman's. The foreman surfaces an approval; you answer
it in the fleet view.

## The typed state

`list_sessions` and `wait_for_events` report a session's state in the crew
vocabulary:

- `working` — a command is running.
- `needs-input` — the agent sent a `Notification` hook; it wants you.
- `needs-approval` — a tool call is blocked, waiting for you to allow or deny.
- `completed` — the agent's turn finished (a `Stop` hook).
- `failed` — the last command exited non-zero.
- `idle` — at a prompt, nothing running.
- `exited` — the shell is gone; the records still read.
- `unknown` — a new shell, or one with no shell-integration marks.

A crew agent must run Claude Code with `kitterm hooks` installed for
`needs-input`, `needs-approval`, and `completed`; `working` comes from its
`PreToolUse` hook, which is recorded and never held. A session with no hooks still
reports `working`, `idle`, `failed`, and `exited` from its shell-integration
marks.

## What holds the terminal

Each row also carries `foregroundProgram`: the name of the program that took
the terminal from the shell, such as `claude` or `vim`. The name is the one
the program was started under, its `argv[0]`, so a pane that runs Claude Code
reads `claude` although the launcher execs a binary named after its version
(ADR 0004). The field is absent when the shell itself is at its prompt. Use it to tell a crew session whose
agent is still running from one whose agent has quit, which the typed state
alone does not say: `completed` means the agent's turn finished, whether or
not `claude` is still there to take the next message. The daemon reads the
field from the kernel when you ask, so it is current at the moment of the
call.

## The loop

A foreman runs one loop over these tools; the goal loop's own steps are
the skill's. This section says how the tools behave in any loop.

1. Spawn a crew session for each task. Name it for the task; label it so the
   fleet is attributable:

   ```
   spawn_session name="payments-retry-bug" labels={crew:"alpha", task:"retry-bug"} input="claude\n"
   ```

   Then read the pane before you send the task ("Read before you type",
   below).

2. Watch the event feed. `kitterm foreman watch` blocks on the feed for the
   sessions it names and exits on the first event that matters, a
   heartbeat, or an epoch change, so a foreman runs it in the background
   and yields its turn (`docs/control-plane.md` gives its flags). The feed
   carries one `agent.status` event per transition: a session that stays
   `working` across many tool calls is silent, and a repeated `needs-input`
   is a new event only when its message changes. `wait_for_events` reads
   the same feed inside a turn; pass the `next` cursor from the last call
   as `since`, and its `epoch` as `epoch`:

   ```
   wait_for_events since=<cursor> epoch=<epoch>
   ```

3. Act on what changed.
   - `needs-input` or `needs-approval` — the human answers, in the pane or
     the fleet view; the foreman routes it and does not answer.

     `send_input` presses Enter after the text the way the session's reader
     expects it: a newline for a shell, a carriage return for an interactive
     `claude`. The daemon looks at what is reading the terminal, so one call
     works for both. Set `enter:false` only to send bare keystrokes, such as
     Ctrl-C.

     Send a whole prompt in one call, whatever its size. The daemon types a
     body into `claude` in pieces of 512 bytes, 50ms apart, then presses
     Enter, because Claude Code keeps only the last read of a paste that
     arrives faster than it reads (`docs/http-api.md` gives the measures).
     A 64 KiB body, the route's cap, takes about 6.5s to type. A prompt
     split across calls is two pastes.

     A text over 1 KiB is refused with a `cooked reader` error while the
     terminal is in cooked mode: a `sleep`, a program that has not yet
     taken raw mode (`claude` takes about a second after it starts), or a
     shell in a here-doc. The kernel keeps 1024 bytes of a cooked line and
     drops the rest, so the text could not arrive whole, and the daemon
     types nothing. The error names what holds the terminal
     (`foregroundProgram`). Once `claude` reads raw keys, the same call
     goes through.
   - `command.failed` — a command exited non-zero in an orchestrated session.
     Read `/commands/<index>/output` (`read_output`).
   - `agent.join-mismatch` — a hook named a session that holds another
     agent's join, from a `cwd` outside that session's project. The daemon
     kept the join and the status. The data names the stranger (`sessionId`,
     `cwd`, `transcript`): a process that inherited the pane's
     `KITTERM_SESSION_ID`. Report it once; the stranger's own state is on no
     row.

4. End a session when its work merges. `kill_session` ends the shell now.
   The linger clock does not do it for you: it reaps an idle shell, not a
   working session. A crew session with `claude` in the foreground, or one
   that still prints output, is held past every window, whether or not a
   browser is open on it (ADR 0002). Only a shell at its prompt that printed
   nothing for a whole window goes on its own. A session you forget stays
   until you end it.

5. End the sessions held past your own tolerance. The daemon tells you which
   ones it holds, and never decides for you:
   - A held row carries `heldSince`, the epoch millisecond when the first
     window expired and the clock kept the session. It is set once, stays
     until a client attaches or the session ends, and is absent on a session
     the clock is not holding.
   - Each time a window expires and the clock keeps a session, the feed
     carries `session.lingered`. Its data says why: `reason` is `foreground`
     with the `program` name (`claude`, `vim`, `sleep`), or `output`, and
     `heldSince` repeats the row's value.

   Pick a tolerance for your crew (an hour past `completed`, a day for a
   session that waits on a human) and act on it: on `session.lingered`, or
   on each `list_sessions`, compare `heldSince` with now. A held session with
   `claude` at an empty prompt and nothing left to do is one you forgot.
   `kill_session` it, or `archive_session` it when its output is worth
   keeping. The 64 session ceiling is the only bound the daemon applies.

## One foreman for every scope

One foreman runs per scope and serves every project under it.
`docs/goals/LOOP.md` gives the scope, the package, the branch
`goal/<slug>`, its pull request and the merge; the skill gives the steps,
from `kitterm foreman catch-up` and
`kitterm project init --refresh --check <root>` on. `docs/control-plane.md`
gives the commands the steps run: `kitterm goal new`, `kitterm goal list`,
`kitterm round open` and `kitterm round close`.

## Read before you type

`read_output` returns the raw bytes of one command. For a pane that runs a
TUI such as Claude Code, those bytes are spinner redraws and cursor moves.
`read_screen` returns the screen a human sees, at the pane's size, with the
cursor position, and marks a dim run as `{dim}…{/dim}`. On 2026-09-04 a
foreman read Claude Code's dim ghost suggestion on an empty prompt as typed
text and pressed Enter on nothing, and it typed a task into a pane that was
still at the folder-trust dialog. So the foreman reads before it types, by
the "Read before you type" steps of the skills under `examples/foreman/`.
The steps rest on these facts:

- `screen_state` counts every answer in `~/.kitterm/screen-state.log`;
  `kitterm screen-state stats` shows how often the rules say `unknown`.
- The trust dialog is not a permission dialog: it asks about the folder the
  foreman chose. A permission dialog is the human's, and the fleet view
  holds the same dialog.
- A client that strips an escape byte types `[B` as text, and a client
  that passes it raw breaks the JSON-RPC line, so a key goes by name.
- A keystroke and a carriage return in one write can confirm the option
  that was marked before the keystroke arrived, so the arrow and the
  Enter go in two calls.

## When the daemon upgrades in place

`kitterm upgrade --live` replaces the daemon process with the new build and
keeps every shell. Your session ids stay valid, the agents in them keep
running, and the event feed keeps its `epoch`. What you see:

- A `wait_for_events` or `wait_for_command` call that is in flight fails once
  with a connection error. Call it again with the same `since` and `epoch`.
  The answer is not `pruned`.
- The first new event is `daemon.started` with `takeover` set to `"true"` and
  the same `epoch`. Its `version` is the new build.
- A `send_input` call that was in flight may have been cut. Run "Read before
  you type" and send the text again if the screen does not show it.

Do not re-list or respawn anything. Continue the loop with the `next` cursor.

## When the daemon restarts

A daemon restart (`kitterm restart`, `kitterm upgrade --restart`, a crash)
closes every shell. Every session id you hold is gone, and the event feed
starts again from zero. The feed tells you so:

- Every `wait_for_events` result carries the daemon's `epoch`. A new value
  means a new daemon process.
- The first event of the new epoch is `daemon.started`. Its data holds the
  `epoch`, the daemon `version`, and its `pid`.
- A call whose `since` or `epoch` belongs to the old daemon answers at once
  with `pruned` true and every event of the new epoch, `daemon.started` first.

When the epoch changes, do this:

1. Forget every session id you hold. The sessions are gone. A session you
   spawned with `spawn_session` does not come back.
2. Call `list_sessions` again. A browser pane that was open reconnects and gets
   a new shell with a new id. The new shell keeps the old name and labels, and
   the pane sends the old cwd, so match a respawned session by its labels and
   its cwd, never by its id. Its `session.created` event also carries
   `respawnOf`, the id the pane held before.
3. Spawn again what is missing. A respawned shell is a fresh shell: the agent
   that ran in it is gone, so send it its task again.
4. Continue the loop with the new `epoch` and the `next` cursor from the
   `pruned` result.

Note the limit: a respawned shell keeps its name, labels, and cwd, not its
process. A restart costs every crew agent its run; an in-place upgrade
(`kitterm upgrade --live`) does not.

## Crew conventions

Use labels so a fleet of sessions stays attributable.

- `crew:<name>` groups the sessions one foreman manages.
- `task:<slug>` names the piece of work a session owns.
- `traceparent:<w3c>` passes a trace context through, so a session's commands
  correlate with a span you own. kitterm emits no traces itself.

Filter the fleet by any label: `list_sessions label="crew:alpha"`.

The goal loop reserves keys of its own; the Labels table in
`docs/goals/LOOP.md` is the one list of them. `kitterm round open` sets them
on every crew session it spawns for a round. The foreman's own pane carries
`crew:foreman`; the fleet view pins that session above the project cards and
reads "no foreman running" when none exists.

## What a human sees

Open `/sessions` from any device. The fleet view shows every crew session with
its typed state, its name, and its last command. It repaints the instant a
session changes — it holds an event long-poll, not only a timer. A blocked
approval sits at the top of the page, so you answer it from a phone. This is
the same truth the foreman reads, so you and the foreman never disagree about
what a session is doing. A registered project's card also shows every goal
folder under its `docs/goals/`: an `active` goal expanded with its title and
slug, `round N of M`, its status, the next action, a link to the proposals
waiting on you, and a link to the latest round record; a `waiting`,
`stopped`, or `done` goal as one line with its status and its latest record,
plus the proposals link while it waits. A session with a `goal:` label sits
under that goal's sub-header with its round; a label no folder carries reads
`(no folder)`.

## Example skills

`examples/foreman/` holds reference Claude Code skills you copy and tune:

- `foreman-loop.md` — the standing foreman: the procedure of the goal loop.
- `review-crew.md` — spawn a review session per dimension, collect the notes.
- `triage.md` — reproduce a bug in its own session, confirm the root cause.

`kitterm skills install` writes each of them to `~/.claude/skills/<name>/SKILL.md`,
and the crew settings file `crew-settings.json` (`docs/control-plane.md`)
beside `foreman-loop` (`--dir <path>` picks another directory). It prints one line per file:
`wrote`, `updated`, or `unchanged`. `kitterm skills list` prints the names and
descriptions. The binary embeds the files, so the installed skills match the
release that installed them.
