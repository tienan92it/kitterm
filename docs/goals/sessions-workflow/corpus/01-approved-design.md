# The approved design

The human approved the three frames of `design/sessions.pen` on
2026-10-05, in the foreman's pane ("Approve"), at commit `2762a02` on
`goal/sessions-workflow`: `Sessions 1200`, `Sessions 390` and
`Sessions components`, exported to `design/exports/`. Capability 5
builds the SESSIONS section from the file at that commit.

## What the approval adds to the stage table

The frames draw three rules that `00-request.md` does not state. The
approval makes them part of the contract:

1. `done` wins over a waiting proposal and over the status rows: a goal
   whose status is `done`, or whose pull request is merged, is `done`
   even when a proposal still waits.
2. `blocked` has two marks by its cause. A person blocks it
   (`needs-input`, `needs-approval`, status `waiting` or `stopped`, a
   proposal): `?` in the warning colour. A failure blocks it (a `failed`
   session, a task under `## Failures`, CI ✗): `!` in the danger
   colour. The word stays `[blocked]`, and the legend prints `? !
   [blocked]`.
3. A goal with no open task starts closed, and a project whose goals are
   all done starts closed, with its count (`10 done`).

## What the file does not carry

Two foundation fixes did not survive the save in Pen: the line heights
hold the right numbers (28 at 1200, 44 at 390) with no binding to
`$line-compact` and `$line-touch`, and the pull request link has no
underline property. `design/foundation.md` rules for both, and the page
follows the foundation.
