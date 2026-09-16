# STATE: workspace-ledger

- Status: active
- Round: 0 of 3 in this budget (first budget)
- Rounds total: 0
- Last floor: green (2026-09-16, main at aa7c956: swift test 729, vitest 1222)
- Updated: 2026-09-16, planned

## Queue

1. `three-levels-no-filters` (capability 1)
2. `answer-from-the-page` (capability 2)
3. `capture-the-quota` (capability 3)
4. `daily-rollup` (capability 4)
5. `the-numbers-on-the-page` (capability 5)

## Failures

None.

## Proposals waiting on the human

None.

## Done

None.

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

Round 1: `three-levels-no-filters` from `plan.md` row 1. It is the
foundation: every later capability hangs its numbers on the headings it
creates. Capabilities 2 and 3 are independent of it and may run beside
it; 4 must land before 5.
