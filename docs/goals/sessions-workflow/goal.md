# Goal: the SESSIONS tree shows each scope's work stage and the PRs to review

## Objective

The human opens `/sessions` and reads the SESSIONS section as one simple
tree: workspace, then project, then goal, then task, then session. Every
goal and task line says its stage in one word (`plan`, `build`,
`review`, `blocked`, `done`), and every goal with a pull request shows
that pull request's state: draft, ready, CI passing, failing or
pending, merged. A line under the section header names the pull requests
that are ready for review, so the human can review at any time. Within
two minutes of a merge on GitHub the tree shows the merge and the goal's
`STATE.md` from the merged base branch, with no `git pull` in the
checkout. The daemon reads pull request state with `gh` on its own
queue.

## Exclusions

- The panels above the tree (the band, `USAGE`, `QUOTA`, `MODELS`,
  `VALUE`, `WHERE`, `LEAKS`) do not change.
- No queue column, no cards, no canvas, no detail panel: the section
  stays a tree of one-line rows.
- The page accepts no typed work and holds no action. A link to a pull
  request on GitHub is a link, not an action.
- The daemon never writes a project's checkout or its `docs/goals/`
  package. A `git fetch` updates remote-tracking refs only.
- No GitHub token file and no GitHub REST client: `gh` and the human's
  own `gh` login are the only source.

## Completion condition

All 7 hold on a build from `main`:

1. The SESSIONS section at 1200 px and 390 px matches the frames of
   `design/sessions.pen` at the commit `corpus/01-approved-design.md`
   names, on the real `docs/goals/` tree.
2. Every goal line and every task line shows exactly one stage word from
   `plan`, `build`, `review`, `blocked`, `done`, decided by the table in
   `corpus/00-request.md`; a vitest pins every row of that table.
3. A goal line with a pull request shows `PR #N` as a link with its
   state (`draft`, `ready`, `CI ✓`, `CI ✗`, `CI …`, `merged`), from a
   daemon route fed by `gh pr list` per GitHub project at most once a
   minute, never on the event loop.
4. The line under the SESSIONS header counts the pull requests that are
   ready for review and links each one; with none, it says so.
5. Within two minutes of a merge on GitHub, with no `git pull`, the goal
   line shows `merged` and its tasks come from the base branch's
   `STATE.md`.
6. A project with no GitHub remote, a machine with no `gh`, or a `gh`
   with no login shows the pull request numbers as today, and one line
   says why; no other part of the page changes.
7. The tree on a phone (390 px) keeps the stage word and the pull
   request state; the other columns may drop.

The floor (Linux build, `swift test`, the web checks, the bench) is
green at every step.
