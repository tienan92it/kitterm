---
name: triage
description: Triage a bug in its own kitterm session — reproduce it, find the root cause, and confirm the cause before any fix. Use when the user reports a bug and wants it investigated in an isolated session rather than fixed blind.
---

# Bug triage

You triage one bug in its own session. You reproduce it, you find the cause, and
you confirm the cause. You do not fix it until the user asks.

## Read before you type

Do this before every `send_input` into a pane that runs an interactive agent.

1. Call `read_screen`. Find the row the cursor is on.
2. Type only when the prompt is at the cursor and the input box is empty: the
   cursor row reads `❯` and the cursor sits right after it. A `{dim}…{/dim}`
   run at the cursor is a placeholder. Treat it as empty. Never treat it as
   text, and never press Enter on it.
3. When the screen shows something else, do not type the message. Act on what
   the screen shows:
   - Trust dialog — "Is this a project you created or one you trust?" with
     the options `No, exit` and `Yes, I trust this folder`. When the cwd is
     the repo the user named, move the mark to `Yes, I trust this folder`
     with `send_input keys=["down"]`. A key goes by name because an escape
     byte does not survive an MCP client's JSON string argument. Read the
     screen to confirm `❯` sits on that option, then press Enter with
     `send_input keys=["enter"]`. Any other cwd: stop and tell the user.
   - Permission dialog — "Do you want to proceed?" or a numbered choice with
     a `Yes` and a `No`. Never answer it. Tell the user and link the pane.
   - In-progress turn — a spinner line with "esc to interrupt", or a `⏺`
     tool call above an empty prompt that has not returned. Wait. Call
     `wait_for_events` until the session reports `completed` or
     `needs-input`, then read the screen again.
4. Send the message with `send_input`. Send one dialog keystroke per call, and
   read the screen between keystrokes.
   A `cooked reader` error means the program in the pane has not taken raw mode
   yet (the error names it in `foregroundProgram`), a text over 1 KiB could not
   arrive whole, and nothing was typed. Go back to step 1. Set `force:true`
   only for a shell that reads lines under 1 KiB as they come.
5. Call `read_screen` again. Confirm the text you typed now appears above the
   input box as `❯ <your text>` and the box is empty again. When the text
   still sits in the box, press Enter alone (`send_input text=""`) and read
   once more.

## Steps

1. Spawn a session for the bug:
   `spawn_session name="triage-<bug>" cwd="<repo>" labels={crew:"triage", task:"<bug>"} input="claude\n"`

2. Run "Read before you type", then send the triage prompt with `send_input`:
   the bug report, the repo, and the instruction to reproduce first.

3. Drive the session to reproduce the bug. Run "Read before you type" before
   each `send_input`. Read the pane with `read_screen`; use `wait_for_command`
   then `read_output` only for a shell command the session runs outside
   `claude`. Do not accept a theory that has no reproduction.

4. Once reproduced, drive the session to find the root cause. Rank the
   candidate causes, test the most likely first, and confirm which one the
   evidence supports.

5. Post the finding with `post_note`: the reproduction steps, the confirmed
   root cause, and the file and line. Then report it to the user.

6. Stop. Do not fix the bug. Ask the user whether to fix it, and wait.

## Rules

- Reproduce before you theorize. A cause with no reproduction is a guess.
- Confirm the cause. Name the evidence — the failing input and the wrong
  output.
- Add a regression test that fails before any fix, when the user asks for the
  fix.
- When the triage session carries a `goal:` label, the confirmed root cause
  also goes into that round's record, `docs/goals/<slug>/rounds/NNN.md`, under
  "Gap" with its evidence. The foreman writes it there; the triage session
  never edits the record. Spawn such a session with the `goal:` and
  `round:` labels of the round it serves.
