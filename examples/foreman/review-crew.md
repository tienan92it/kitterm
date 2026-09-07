---
name: review-crew
description: Review a chunk of work with a crew of independent review sessions through kitterm, one per dimension (security, accessibility, performance, reuse), then collect and dedupe their findings. Use when the user wants a multi-angle code review of a branch or a diff.
---

# Review crew

You run an independent review of a chunk of work. You spawn one review session
per dimension, each blind to the others, then collect their findings.

## Read before you type

Do this before every `send_input` into a review session.

1. Call `read_screen`. Find the row the cursor is on.
2. Type only when the prompt is at the cursor and the input box is empty: the
   cursor row reads `❯` and the cursor sits right after it. A `{dim}…{/dim}`
   run at the cursor is a placeholder. Treat it as empty. Never treat it as
   text, and never press Enter on it.
3. When the screen shows something else, do not type the prompt:
   - Trust dialog — "Is this a project you created or one you trust?". When
     the cwd is the repo under review, send one Down arrow
     (`send_input text="\u001b[B" enter=false`), read the screen to confirm
     `❯` sits on `Yes, I trust this folder`, then press Enter alone
     (`send_input text=""`). Any other cwd: stop and tell the user.
   - Permission dialog — "Do you want to proceed?" with a `Yes` and a `No`.
     Never answer it. Tell the user and link the pane.
   - In-progress turn — a spinner line with "esc to interrupt". Wait with
     `wait_for_events` until the session reports `completed` or
     `needs-input`, then read the screen again.
4. Send the prompt with `send_input`. One dialog keystroke per call.
   A `cooked reader` error means the program in the pane has not taken raw mode
   yet (the error names it in `foregroundProgram`), a text over 1 KiB could not
   arrive whole, and nothing was typed. Go back to step 1. Set `force:true`
   only for a shell that reads lines under 1 KiB as they come.
5. Call `read_screen` again. Confirm the prompt appears above the input box as
   `❯ <your text>` and the box is empty. When the text still sits in the box,
   press Enter alone (`send_input text=""`) and read once more.

## Steps

1. Pick the dimensions the work needs. Common ones: security, accessibility,
   database and performance, code reuse, test coverage. Do not run all of them
   on every change; choose the ones the diff touches.

2. Spawn one session per dimension. Give each the same diff and a different
   review criterion:
   `spawn_session name="review-<dimension>" labels={crew:"review", task:"<dimension>"} input="claude\n"`
   Run "Read before you type", then `send_input` the review prompt: the diff
   to read, the one dimension to judge, and the instruction to post its
   findings with a note.

3. Wait for the crew with `wait_for_events since=<cursor> epoch=<epoch>`. Each
   session posts its findings as a `note` and then reports `completed`. A
   changed `epoch` means the daemon restarted and the crew is gone: list the
   sessions again and respawn the missing reviewers.

4. Collect the notes. Dedupe overlapping findings. Rank each from nit to
   blocking.

5. Give the user one merged, ranked list. Name the session each finding came
   from.

6. `kill_session` for every review session once you have its findings. A review
   session's job ends when it hands back its review.

## Rules

- The review sessions are independent. Do not let one see another's findings.
- You collect and dedupe; you do not add your own findings.
- A finding is blocking only if it breaks correctness, security, or a shipped
  feature. Everything else is a nit or a suggestion.
