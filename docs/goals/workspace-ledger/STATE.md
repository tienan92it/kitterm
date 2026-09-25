# STATE: workspace-ledger

- Status: done
- Round: 3 of 3 in this budget (second budget)
- Rounds total: 6
- Last floor: green (2026-09-16, round 6 after: swift test 780, vitest 1286 in 41 files; no `Sources/` change, so no Linux build and no bench)
- Updated: 2026-09-17, the human set the goal done

## Queue

Empty.

## Failures

None.

## Proposals waiting on the human

None.

2026-09-25, the foreman closed all three: the human amended the corpus
number in `2eee3cf`; `agent-dashboard` now owns the chart; PR #128
replaced the strip with the band.

## Done

- `the-strip-holds-only-what-needs-you` (capability 6), round 6, PR #124.
  See `rounds/006.md`. A proposal on a `done` or `stopped` goal leaves
  the strip and stands on the goal's own line, where its count links
  `STATE.md`. Measured on the real tree: 12 strip items to 2, the 390 px
  page 1720 px to 1238, the strip ending at 282 instead of 764.
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

None. The human set the goal `done` on 2026-09-17 and amended the corpus
request in the same answer.

All six conditions in `goal.md` hold on `main` at `7996ebb`, released as
v0.30.0 and upgraded in place. The page groups by workspace, project and
goal state with no filters. A foreman or crew row takes a typed answer.
`GET /api/usage/limits` serves the newest quota reading with its age.
The daemon keeps a daily rollup that outlives the 30-day transcript
retention. Every heading carries its cost and cache share beside the
panel. `main` was green after every merge.

Measured on the live daemon on 2026-09-16: last 30 days $1,177.28,
`kitterm` $926.21 at 98% cached, this goal itself $75.11. The page at
390 px is 1238 px tall, from 2820 px before the two dashboard goals.

One step stays with the human and is not a defect: run
`kitterm statusline install`. The quota block reads "No quota reading
yet" until a statusline render posts one.

To reopen: set `Status: active`, write a queue, and set
`Round: 0 of 3 in this budget (third budget)`.
