# Goal: VALUE shows the fleet's lifetime totals and unit costs as two charts

## Objective

Under the VALUE tiles, the human sees two line charts, whatever
the 7d/30d/90d toggle says. TOTALS draws how the cumulative spend, merged
pull requests, merged lines and releases grew against each other: each
divided by its own value on 3 Sep, on a log axis, from 3 Sep to today,
the multiple at the line's end (`×26.2 lines`) and the real totals in
shorthand in the tooltip. UNIT COSTS draws, on one dollar axis, the
lifetime cost per merged pull request, per 1,000 merged lines, per
release and per hour of model time. A tooltip gives a day's values, and
a note says that spend before early September is mostly missing from
the record. The daemon answers the counts per day that the charts need.
The direction is `corpus/02-direction.md`, which replaces the indexed
chart of `corpus/00-request.md`.

## Exclusions

- The tiles, the other panels and the tree do not change, but for the
  room the charts take.
- No new price, no estimate: spend is the rollup's billed dollars, as
  VALUE uses today.
- No colour outside the design foundation; the lines differ by dash.
- No day before the first recorded spend day.

## Completion condition

All 6 hold on a build from `main`:

1. The VALUE section at 1200 px and 390 px matches the frames of
   `design/dashboard.pen` at the commit `corpus/03-approved-design.md`
   names.
2. Each TOTALS line on day d is the cumulative value from the first spend
   day to d; each UNIT COSTS line is the rule of
   `corpus/02-direction.md`; a vitest pins the arithmetic on a fixture,
   and a check against the live daemon matches the human's table on
   three days.
3. Large numbers print in shorthand (`k`, `m`, `b`), and the unit costs
   in dollars with two decimals under $100 and whole dollars above.
4. The daemon answers merged pull requests, merged lines and releases
   per day over a range, from git on its own queue, cached, never on the
   event loop, full grade only.
5. A watch page shows no chart, as it shows no cost.
6. A fleet with no spend prints one sentence in place of the charts.

The floor (Linux build, `swift test`, the web checks) is green at every
step.
