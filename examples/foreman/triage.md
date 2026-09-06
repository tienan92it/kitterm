---
name: triage
description: Triage a bug in its own kitterm session — reproduce it, find the root cause, and confirm the cause before any fix. Use when the user reports a bug and wants it investigated in an isolated session rather than fixed blind.
---

# Bug triage

You triage one bug in its own session. You reproduce it, you find the cause, and
you confirm the cause. You do not fix it until the user asks.

## Read before you type

Do this before every `send_input` into the triage session while `claude` runs
in it.

1. Call `read_screen`. Find the row the cursor is on.
2. Type only when the prompt is at the cursor and the input box is empty: the
   cursor row reads `❯` and the cursor sits right after it. A `{dim}…{/dim}`
   run at the cursor is a placeholder. Treat it as empty. Never treat it as
   text, and never press Enter on it.
3. When the screen shows something else, do not type the message:
   - Trust dialog — "Is this a project you created or one you trust?". When
     the cwd is the repo the user named, send one Down arrow
     (`send_input text="\u001b[B" enter=false`), read the screen to confirm
     `❯` sits on `Yes, I trust this folder`, then press Enter alone
     (`send_input text=""`). Any other cwd: stop and tell the user.
   - Permission dialog — "Do you want to proceed?" with a `Yes` and a `No`.
     Never answer it. Tell the user and link the pane.
   - In-progress turn — a spinner line with "esc to interrupt". Wait with
     `wait_for_events` until the session reports `completed` or
     `needs-input`, then read the screen again.
4. Send the message with `send_input`. One dialog keystroke per call.
5. Call `read_screen` again. Confirm the message appears above the input box
   as `❯ <your text>` and the box is empty. When the text still sits in the
   box, press Enter alone (`send_input text=""`) and read once more.

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
