# STATE: workspace-ledger

- Status: active
- Round: 2 of 3 in this budget (second budget)
- Rounds total: 5
- Last floor: green (2026-09-16, round 5 after: swift test 780, vitest 1273, bench p95 2.68 ms, Linux green)
- Updated: 2026-09-16, round 5 closed

## Queue

1. `the-strip-holds-only-what-needs-you` (capability 6, proposed by
   round 5). Eleven proposals from goals that are `done` stand above the
   usage panel and above the work on the live page. A returning reader
   meets a screen of items that no longer need them. Corpus request `01`
   says the strip is "as today", so round 5 left it; the human charters
   this item or drops it.

## Failures

None.

## Proposals waiting on the human

- `corpus/01-where-did-it-go.md` line 5 says `kitterm` is $699.93. The
  route says $906.68 today, because the research counted the main
  directory alone and `ProjectStore` folds the worktrees in. The corpus
  is Frozen, so the human updates the number. The page is built against
  the route.
- `plan.md` row 5 says "sparkline". Round 5 shipped one SVG bar a day, so
  a silent day is a visible gap and the chart adds no colour pair for the
  ratchet to measure. The plan is the human's to change.
- Capability 6, the strip item in the queue above, needs the human to
  charter it: it changes what corpus request `01` calls "as today".

## Done

- `the-numbers-on-the-page` (capability 5), round 5, PR #123. See
  `rounds/005.md`. Every workspace, project and goal heading carries its
  dollars and its cache share; the panel shows the total, one bar a day,
  and the cost/tokens and 7/30/90-day toggles. A goal's cost sums the
  `- Cost:` lines of its round records, the only join between a goal and
  the rollup, which keys on a directory. Live: 30 days $1,155.48,
  `kitterm` $906.68 at 98% cached, the `workspace-ledger` goal $55.58.
  `AGENTS.md` and `docs/architecture.md` now describe the page as it is.
- `capture-the-quota` (capability 3), round 4, PR #122. See
  `rounds/004.md`. A statusline render posts the `rate_limits` object it
  is given; the daemon keeps the newest and serves it with its age. The
  page draws one text-cell bar per window with the reset countdown, and
  says when it has never been given a reading. Proved with a real
  reading: five-hour 34%, seven-day 36%, captured from a throwaway
  `claude` on scratch daemon 3944.
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

All five planned capabilities are done and merged. The goal's completion
condition holds on `main` once PR #123 merges: the page groups by
workspace, project and goal state with no filters; a foreman or crew row
takes a typed answer; `GET /api/usage/limits` serves the newest quota
reading with its age; the daemon keeps a daily rollup that outlives the
30-day transcript retention; and every heading carries its cost and cache
share beside the panel.

Round 5 found one defect outside its item and it is the queue's only
entry: the strip shows eleven proposals from goals that are `done`. The
human charters capability 6 or sets the goal to `done`.
