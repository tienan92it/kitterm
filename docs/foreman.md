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
| `list_sessions` | Every crew session with its typed state, name, and last command. |
| `get_session` | One session's full status row. |
| `spawn_session` | Start a crew session. Name it; optionally set cwd, profile, labels, and an initial input line. |
| `rename_session` | Set a session's name, note, or labels. |
| `send_input` | Type into a session — a message, an answer, or a command. |
| `list_commands` | The commands a session ran, with exit codes. |
| `wait_for_command` | Block until a command finishes, then read its exit code. |
| `read_output` | Read a command's captured output. |
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

## The loop

A foreman runs one loop.

1. Spawn a crew session for each task. Name it for the task; label it so the
   fleet is attributable:

   ```
   spawn_session name="payments-retry-bug" labels={crew:"alpha", task:"retry-bug"} input="claude\n"
   ```

2. Wait on the event feed. One `wait_for_events` call watches every session at
   once — it returns the moment any session changes state, an approval appears,
   or an agent posts a note. Pass the `next` cursor from the last call as
   `since`:

   ```
   wait_for_events since=<cursor>
   ```

3. Act on what changed.
   - `needs-input` or `needs-approval` — tell the human, and route them to the
     pane. Do not answer for them.
   - `note` — a crew agent reported progress ("plan ready for review"). Relay
     it.
   - `completed` — verify the work, then move the session to review or end it.

4. End a session when its work merges. `kill_session` ends the shell now,
   instead of leaving it on the linger clock.

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
