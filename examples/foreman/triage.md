---
name: triage
description: Triage a bug in its own kitterm session — reproduce it, find the root cause, and confirm the cause before any fix. Use when the user reports a bug and wants it investigated in an isolated session rather than fixed blind.
---

# Bug triage

You triage one bug in its own session. You reproduce it, you find the cause, and
you confirm the cause. You do not fix it until the user asks.

## Steps

1. Spawn a session for the bug:
   `spawn_session name="triage-<bug>" cwd="<repo>" labels={crew:"triage", task:"<bug>"} input="claude\n"`

2. Send the triage prompt with `send_input`: the bug report, the repo, and the
   instruction to reproduce first.

3. Drive the session to reproduce the bug. Use `send_input` to run commands and
   `wait_for_command` then `read_output` to read what happened; when the
   session runs a TUI, read the pane with `read_screen` instead. Do not accept a
   theory that has no reproduction.

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
