# The human's request

2026-10-08, in the foreman's pane:

> What if I want to see the lifetime cost of VALUE section? It will be a
> line chart, each line is lifetime cost of "merged pull requests",
> "merged lines added", "releases"...

The foreman's facts, the same day: recorded spend starts on 2026-08-10
(52 days with spend, $6,291, 1,070 sessions in the rollup); kitterm's
git history starts on 2026-07-16; `GET /api/yield` answers totals for a
range and no series per day.

The human's choices from three previews each:

1. **One chart, indexed lines.**

```
LIFETIME   index, 10 Aug = 100
200 │╲
    │ ╲   ── $/PR   ─ ─ $/line   ··· $/release   ─·─ $/hour
100 │  ╲____
    │ ······╲────────────────
 50 │─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
    └─────────────────────────
     10 Aug                       8 Oct
```

2. **Lifetime, always.** Every line starts at the first recorded spend
   day and ends today, whatever the 7d/30d/90d toggle says; the VALUE
   tiles' numbers keep following the toggle.
3. **Design in Pen, then build.**

## What a line is

For each of the four VALUE units (merged pull requests, merged lines
added, releases, hours of model time), the lifetime unit cost on day d
is the spend from the first spend day to d, divided by the units
delivered from the first spend day to d. The hours line divides the
spend of the sessions that carry a duration (`measuredUSD`) by their
model hours (`apiMs`), as the hours tile does. The index on day d is
that unit cost over the unit cost on the line's base day, times 100.

## Rules the foreman set, for the human's approval with the design

- A line's base day is its first day with a count above zero; the line
  starts there, so no index divides by zero.
- The four lines differ by their dash pattern (solid, dashed, dotted,
  dash-dot) in the one data colour, each named at its right end; the
  dollar value of a day is in its tooltip.
- The counts are summed over the projects VALUE counts today.
