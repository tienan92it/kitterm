# Goal: VALUE shows how each unit cost moved over the fleet's lifetime

## Objective

Under the VALUE tiles, the human sees one line chart, LIFETIME: four
lines, the lifetime cost per merged pull request, per merged line, per
release and per hour of model time, each as an index that starts at
100 on its base day, from the first recorded spend day to today. A
tooltip gives the day, the index and the dollar value. The chart does
not follow the 7d/30d/90d toggle; the tiles do. The daemon answers the
counts per day that the chart needs.

## Exclusions

- The tiles, the other panels and the tree do not change, but for the
  room the chart takes.
- No new price, no estimate: spend is the rollup's billed dollars, as
  VALUE uses today.
- No colour outside the design foundation; the lines differ by dash.
- No day before the first recorded spend day.

## Completion condition

All 5 hold on a build from `main`:

1. The VALUE section at 1200 px and 390 px matches the frames of
   `design/dashboard.pen` at the commit `corpus/01-approved-design.md`
   names.
2. Each line's value on day d equals the rule of `corpus/00-request.md`
   for the real rollup and the real git history; a vitest pins the
   arithmetic on a fixture, and a check against the live daemon matches
   on three days.
3. The daemon answers merged pull requests, merged lines and releases
   per day over a range, from git on its own queue, cached, never on the
   event loop, full grade only.
4. A watch page shows no chart, as it shows no cost.
5. A line with no count yet, or a fleet with no spend, prints one
   sentence in place of the chart.

The floor (Linux build, `swift test`, the web checks) is green at every
step.
