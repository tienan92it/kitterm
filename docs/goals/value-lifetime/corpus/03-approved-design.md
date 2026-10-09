# The approved design

The human approved the VALUE frames of `design/dashboard.pen` on
2026-10-09, in the foreman's pane ("Approve, go"), at commit `4b8379e`
on `goal/value-lifetime`: the TOTALS and UNIT COSTS charts under the
VALUE tiles in `Dashboard 1200` and `Dashboard 390`, and their parts in
`Components` (the colour keys, the shorthand rule, the note, the empty
state), exported to `design/exports/`. Capability 4 builds the charts
from the file at that commit.

## What the approved frames hold

- **TOTALS:** growth since the base day on a log axis (×1, ×2, ×5, ×10,
  ×20, ×50): each measure's cumulative value over its value on the base
  day; end labels `×26.2 lines`, `×9.0 PRs`, `×8.8 spend`,
  `×4.1 releases`, stacked with a leader when closer than one line
  height; a tooltip with the day's multiples and its real totals in
  shorthand.
- **UNIT COSTS:** dollars since the first recorded spend day (10 Aug) on
  one axis: $/PR, $/1k lines, $/release, $/hour, each named at its end
  with today's value; a tooltip with the day's four values.
- **The note:** "Spend before early September is mostly missing from
  the record, so the August unit costs read low."
- **The colours (Set 3), one per measure in both charts:** `data-1`
  #04c7a0/#11866c spend and $/hour, `data-2` #f7ab07/#9c6d1a PRs and
  $/PR, `data-3` #5582f7/#446fe2 lines and $/1k lines, `data-4`
  #fe2497/#e40784 releases and $/release; the Data palette section of
  `design/foundation.md`.

## The base day (the foreman's rule, for the human to change)

The frames draw 3 Sep. The page finds it: the base day is the first day
of the first run of seven days that each have recorded spend. On the
real rollup that is 2026-09-03 (09-03 to 09-09: $428, $419, $31, $100,
$177, $187, $232); every earlier seven-day run holds a day with $0.

## The base day, decided (2026-10-09)

Round 3 found the rule above too fragile: the foreman had read rounded
numbers, and 2026-08-23 holds $0.09, not $0, so "each day has recorded
spend" makes 22 Aug to 28 Aug a run and picks 22 Aug. The foreman
showed the real days (08-20 $6.63, 08-21 $0, 08-22 $16.67, 08-23 $0.09,
… 09-02 $0, 09-03 $427.76) and floors from $1 to $25, which all give
3 Sep. The human chose:

> 7 days, each ≥ 25% of median

The base day is the first day of the first run of seven days in which
every day's spend is at least a quarter of the median daily spend over
the whole record. On the rollup of 2026-10-09 the median is $48.94, the
floor $12.23, and the base day 2026-09-03 (its run: $427.76, $419.29,
$31.41, $100.41, $176.95, $186.96, $231.77). This replaces "each have
recorded spend" above.
