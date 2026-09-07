# Running a foreman with kitterm

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
| `list_sessions` | Every crew session with its typed state, name, last command, and what holds its terminal. |
| `get_session` | One session's full status row. |
| `spawn_session` | Start a crew session. Name it; optionally set cwd, profile, labels, and an initial input line. |
| `rename_session` | Set a session's name, note, or labels. |
| `send_input` | Type into a session and press Enter — a message to its agent, an answer, or a command. Refuses a text over 1 KiB while a cooked reader holds the terminal; `force:true` overrides. |
| `list_commands` | The commands a session ran, with exit codes. |
| `wait_for_command` | Block until a command finishes, then read its exit code. |
| `read_output` | Read a command's captured output. |
| `read_screen` | Read what a pane shows, rendered at its real size. Use it before you type into a TUI. |
| `wait_for_events` | Block until anything changes across the whole crew. |
| `post_note` | Post a status note onto the event feed. |
| `list_approvals` | The tool calls blocked waiting for a human. |
| `kill_session` | End a session and its shell. |

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
marks. So a non-Claude session works at a basic level, and a Claude session
gets the full vocabulary.

## What holds the terminal

Each row also carries `foregroundProgram`: the name of the program that took
the terminal from the shell, such as `claude` or `vim`. The field is absent
when the shell itself is at its prompt. Use it to tell a crew session whose
agent is still running from one whose agent has quit, which the typed state
alone does not say: `completed` means the agent's turn finished, whether or
not `claude` is still there to take the next message. The daemon reads the
field from the kernel when you ask, so it is current at the moment of the
call.

## The loop

A foreman runs one loop.

1. Spawn a crew session for each task. Name it for the task; label it so the
   fleet is attributable:

   ```
   spawn_session name="payments-retry-bug" labels={crew:"alpha", task:"retry-bug"} input="claude\n"
   ```

   Then read the pane before you send the task ("Read before you type",
   below). A fresh `claude` may still sit at the folder-trust dialog, and a
   task typed into that dialog is lost.

2. Wait on the event feed. One `wait_for_events` call watches every session at
   once — it returns the moment any session changes state, an approval appears,
   or an agent posts a note. Pass the `next` cursor from the last call as
   `since`, and its `epoch` as `epoch`:

   ```
   wait_for_events since=<cursor> epoch=<epoch>
   ```

3. Act on what changed.
   - `needs-input` or `needs-approval` — tell the human, and route them to the
     pane. Do not answer for them. When the human gives you the answer, run
     "Read before you type", then pass the answer on with `send_input`:

     ```
     send_input session=<id> text="Use the retry budget from the config, not a constant."
     ```

     `send_input` presses Enter after the text the way the session's reader
     expects it: a newline for a shell, a carriage return for an interactive
     `claude`. The daemon looks at what is reading the terminal, so one call
     works for both. Set `enter:false` only to send bare keystrokes, such as
     Ctrl-C.

     Send a whole prompt in one call, whatever its size. The daemon types a
     body into `claude` in pieces of 512 bytes, 50ms apart, then presses
     Enter, because Claude Code keeps only the last read of a paste that
     arrives faster than it reads (measured on 2026-09-07: one write of
     2104 bytes reached 2.1.260 as its last 59, and 8193 bytes reached
     2.1.263 as its last 16; the same bodies in paced pieces arrived whole).
     A 64 KiB body, the route's cap, takes about 6.5s to type. Do not split
     a prompt across calls to work around a loss: the split was the
     workaround the daemon now does for you, and a split prompt is two
     pastes.

     A text over 1 KiB is refused with a `cooked reader` error while the
     terminal is in cooked mode: a `sleep`, a program that has not yet
     taken raw mode (`claude` takes about a second after it starts), or a
     shell in a here-doc. The kernel keeps 1024 bytes of a cooked line and
     drops the rest, so the text could not arrive whole, and the daemon
     types nothing. The error names what holds the terminal
     (`foregroundProgram`). Run "Read before you type" again: when the
     prompt is at the cursor, `claude` reads raw keys and the same call
     goes through. Set `force:true` only when you know the reader takes
     lines under 1 KiB as they come, such as a shell fed a script.
   - `note` — a crew agent reported progress ("plan ready for review"). Relay
     it.
   - `completed` — verify the work, then move the session to review or end it.
     A correction goes in the same way: read first, then `send_input`.

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

## Read before you type

`read_output` returns the raw bytes of one command. For a pane that runs a
TUI such as Claude Code, those bytes are spinner redraws and cursor moves.
`read_screen` returns the screen a human sees, at the pane's size, with the
cursor position, and marks a dim run as `{dim}…{/dim}`. On 2026-09-04 a
foreman read Claude Code's dim ghost suggestion on an empty prompt as typed
text and pressed Enter on nothing, and it typed a task into a pane that was
still at the folder-trust dialog. So the foreman reads before it types.

Do this before every `send_input` into a pane that runs an interactive agent.

1. Call `read_screen`. Find the row the cursor is on.
2. Type only when the prompt is at the cursor and the input box is empty: the
   cursor row reads `❯` and the cursor sits right after it. A `{dim}…{/dim}`
   run at the cursor is a placeholder, so an empty prompt can read as
   `❯ {dim}Try "…"{/dim}`. Treat it as empty. Never treat it as text, and
   never press Enter on it.
3. When the screen shows something else, do not type the message. Act on what
   the screen shows:
   - Trust dialog. The pane reads "Is this a project you created or one you
     trust?" with the options `No, exit` and `Yes, I trust this folder`, and
     `❯` marks `No, exit`. This is not a permission dialog: it asks about the
     folder the foreman chose. When the cwd is the repo the user named, send
     one Down arrow (`send_input text="\u001b[B" enter=false`), read the
     screen to confirm `❯` now marks `Yes, I trust this folder`, then press
     Enter alone (`send_input text=""`). Any other cwd: stop and tell the
     user. Send the arrow and the Enter in two calls: a keystroke and a
     carriage return in one write can confirm the option that was marked
     before the keystroke arrived.
   - Permission dialog. The pane reads "Do you want to proceed?" or a
     numbered choice with a `Yes` and a `No`. Never answer it. Tell the user
     and link the pane; the fleet view holds the same dialog.
   - In-progress turn. The pane shows a spinner line with "esc to
     interrupt", or a `⏺` tool call that has not returned above the input
     box. Wait. Call `wait_for_events` until the session reports `completed`
     or `needs-input`, then read the screen again.
4. Send the message with `send_input`. Send one dialog keystroke per call,
   and read the screen between keystrokes.
   A `cooked reader` error means the program in the pane has not taken raw mode
   yet (the error names it in `foregroundProgram`), a text over 1 KiB could not
   arrive whole, and nothing was typed. Go back to step 1. Set `force:true`
   only for a shell that reads lines under 1 KiB as they come.
5. Call `read_screen` again. Confirm the text you typed now appears above the
   input box as `❯ <your text>` and the box is empty again. When the text
   still sits in the box, press Enter alone (`send_input text=""`) and read
   once more.

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
process. Until #47 (live upgrade) lands, an upgrade costs every crew agent its
run.

## Crew conventions

Use labels so a fleet of sessions stays attributable.

- `crew:<name>` groups the sessions one foreman manages.
- `task:<slug>` names the piece of work a session owns.
- `traceparent:<w3c>` passes a trace context through, so a session's commands
  correlate with a span you own. kitterm emits no traces itself.

Filter the fleet by any label: `list_sessions label="crew:alpha"`.

## What a human sees

Open `/sessions` from any device. The fleet view shows every crew session with
its typed state, its name, and its last command. It repaints the instant a
session changes — it holds an event long-poll, not only a timer. A blocked
approval sits at the top of the page, so you answer it from a phone. This is
the same truth the foreman reads, so you and the foreman never disagree about
what a session is doing.

## Example skills

`examples/foreman/` holds reference Claude Code skills you copy and tune:

- `foreman-loop.md` — the spawn / wait / route / end loop above, as a prompt.
- `review-crew.md` — spawn a review session per dimension, collect the notes.
- `triage.md` — reproduce a bug in its own session, confirm the root cause.

These are documentation, not daemon features. The boundary holds: kitterm ships
the machinery, the skill is the foreman's own prompt.
