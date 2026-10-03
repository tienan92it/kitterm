# The human's request

2026-10-03, in the foreman's pane:

> I want to optimze daashboard sessions UI/UX. Currently, it looks too
> complicated and hard to catch up the work processes. It should be
> re-organized, change how to visualize workspace > projects > goals.
> Present the goal PRs better and ready for me to review anytime, auto
> update after I merged. Pick up the workflow UI from this website:
> https://ccdeck.dev/

The answers to the foreman's four questions, the same day:

> 1. Layout: just update sessions section only. Keep the workflow as tree
>    and simple. No need queue and cards. Just clear the workspace scopes,
>    work processes (plan, build, review, blocked, done...) and PRs to
>    review.
> 2. The usage panels: keep it as-is.
> 3. PR data: gh on its own queue.
> 4. Design first via Pen.

## The stage of a line

The foreman's reading of "work processes", for the design round to draw
and the human to approve with the frames. A line takes the first row
that holds, from the top.

| Stage | A goal line | A task line |
|---|---|---|
| `blocked` | a session under it is `needs-input`, `needs-approval` or `failed`; its status is `waiting` or `stopped`; a proposal waits on the human; its pull request's CI fails | the task is under `## Failures`; a session under it is `needs-input`, `needs-approval` or `failed` |
| `review` | its pull request is open and not a draft | its round's pull request is open and not a draft, and no crew session works on it |
| `build` | a live crew session carries its `goal:` label | a live crew session carries its `task:` label |
| `done` | its status is `done`, or its pull request is merged | the task is under `## Done` |
| `plan` | any other active goal: queued work, no live crew, no ready pull request | the task is under `## Queue` and no session carries it |

## What ccdeck shows that this tree takes

ccdeck (https://ccdeck.dev/, read 2026-10-03) draws each Claude Code
session as a card on a canvas, inside a frame per project, with its
subagents joined to it by tree lines. The human declined the canvas,
the cards and the queue column. The tree takes four ideas from it:

- **One status badge per row**, in a small fixed vocabulary
  (`LIVE`, `DONE`, waiting), coloured by urgency, the same on every
  level.
- **The urgent line first.** A session that waits on the human moves to
  the top of its list, with how long it has waited.
- **A frame label per scope** (`INFRA`, `WEB-API · Add rate limiting to
  the public API`): the scope's name and its one-line purpose on one
  line.
- **Joined children.** A child row sits under its parent with a visible
  join, so the eye follows the tree without reading the indent.
