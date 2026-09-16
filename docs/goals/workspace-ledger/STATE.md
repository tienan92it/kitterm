# STATE: workspace-ledger

- Status: active
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-09-16, round 3 after: swift test 757, vitest 1249, bench p95 2.83 ms, Linux green)
- Updated: 2026-09-16, round 3 closed

## Queue

1. `capture-the-quota` (capability 3), running now as round 4.
2. `the-numbers-on-the-page` (capability 5)

## Failures

None.

## Proposals waiting on the human

- `AGENTS.md`'s fleet-view paragraph still describes the filters and the
  tools row, which round 1 removed. Capability 5 rewrites it when the
  page stops changing shape. Not blocking.

## Done

- `answer-from-the-page` (capability 2), round 3, PR #121. See
  `rounds/003.md`. A row whose agent holds the tty takes a line and posts
  it to `POST /api/sessions/<id>/input?enter=1`; a needs-input row
  carries the field in the strip. The send is withheld mid-turn with the
  reason in place of `[send]`, never queued. Proved live: a line typed on
  the page at 390 px reached a `claude` pane on a scratch daemon, which
  answered `PONG`. 390 px height 1326, unchanged.
- `three-levels-no-filters` (capability 1), round 1, `259e38e`. See
  `rounds/001.md`. Workspace, project, goal state; a heading only over
  two or more projects; working read from a live `goal:` label; the
  filter feature gone symbol by symbol. 390 px height 1400 to 1159.
- `daily-rollup` (capability 4), round 2, `ac379ff`. See `rounds/002.md`.
  The daemon keys its rollup on the transcript and sums days at serve
  time, so a refresh is idempotent and a day whose source is gone
  survives. Full scan 2.5 s over 382 MB, no-change 19 ms. It also fixed
  a decoder bug that had been hiding $221.14 from the cost routes.

## Direction

2026-09-16: the human said the session page is still complicated, asked
for grouping by workspace, project and goal state with no filters, for
the foreman and crews to be interactive, and for usage and token
efficiency on the page, with two reference screenshots.

The foreman researched before planning. Two findings shaped the plan.
The quota exists only as a live value handed to a statusline render, so
capability 3 has to capture it rather than read it, and the reference's
per-model row has no local source at all. And Claude Code deletes
transcripts after 30 days, so a 90-day chart needs the daemon to keep its
own rollup, which is why that is its own capability before the page can
draw one.

2026-09-16: the human told the foreman to stay inside kitterm. Another
workspace has its own foreman and this one does not act there or report
its items.

## Next action

The first budget is spent at round 3. The human's standing direction is
to run the remaining capabilities to the end, so the goal continues into
a second budget rather than waiting.

Capability 3, `capture-the-quota`, is running as round 4. Then capability
5, `the-numbers-on-the-page`, which reads round 2's route.

Three things capability 5 must take from the earlier rounds. The corpus
fixture says `kitterm` is $699.93; the route says **$850.51**, because
the research counted the main directory alone and `ProjectStore` folds
the worktrees in. The route is right and the fixture's figure is the one
to update. The last 30 days hold $329.67 apportioned across midnight
over 28 sessions, so the panel must say that rather than imply a
measurement. And at 390 px the goal line already cuts its next action to
"Roun…", so that line needs fixing before a cost is hung on it.
