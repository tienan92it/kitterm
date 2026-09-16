# STATE: workspace-ledger

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-16, round 1 after: vitest 1233 in 37 files)
- Updated: 2026-09-16, round 1 closed

## Queue

1. `daily-rollup` (capability 4), running now, taken out of order because
   capability 5 needs it.
2. `answer-from-the-page` (capability 2)
3. `capture-the-quota` (capability 3)
4. `the-numbers-on-the-page` (capability 5)

## Failures

None.

## Proposals waiting on the human

- `AGENTS.md`'s fleet-view paragraph still describes the filters and the
  tools row, which round 1 removed. Capability 5 rewrites it when the
  page stops changing shape. Not blocking.

## Done

- `three-levels-no-filters` (capability 1), round 1, `259e38e`. See
  `rounds/001.md`. Workspace, project, goal state; a heading only over
  two or more projects; working read from a live `goal:` label; the
  filter feature gone symbol by symbol. 390 px height 1400 to 1159.

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

## Next action

Capability 4, `daily-rollup`, is running as round 2. When it lands,
capability 5 can read its route.

One item for capability 5, from round 1: at 390 px the goal line cuts its
next action to "Roun…" because the title, the round and the next action
share one line. Fix that before hanging a cost on it.
