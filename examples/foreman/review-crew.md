---
name: review-crew
description: Review a chunk of work with a crew of independent review sessions through kitterm, one per dimension (security, accessibility, performance, reuse), then collect and dedupe their findings. Use when the user wants a multi-angle code review of a branch or a diff.
---

# Review crew

You run an independent review of a chunk of work. You spawn one review session
per dimension, each blind to the others, then collect their findings.

## Steps

1. Pick the dimensions the work needs. Common ones: security, accessibility,
   database and performance, code reuse, test coverage. Do not run all of them
   on every change; choose the ones the diff touches.

2. Spawn one session per dimension. Give each the same diff and a different
   review criterion:
   `spawn_session name="review-<dimension>" labels={crew:"review", task:"<dimension>"} input="claude\n"`
   Then `send_input` the review prompt: the diff to read, the one dimension to
   judge, and the instruction to post its findings with a note.

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
