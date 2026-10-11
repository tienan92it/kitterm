# The human's request: a legend, and the charts follow the range

2026-10-11, in the foreman's pane, after v0.39.1:

> The end of line labels look messy. They are overlap each others. Let's
> design a separated chart legend instead of line label

The foreman drew two drafts from the real series (a legend row above
each chart; a legend table beside each chart). The human answered:

> Option A, but no need to show values, just label only. Also,
> recalculate chart according the global filter 7d, 30d, 90d. Plan to add
> lifetime filter if can

The foreman computed the two readings of a range for UNIT COSTS on
9 Oct (lifetime cost zoomed to the range: $26.40, $14.77, $92.03,
$54.92 at every range; cost within the range, 7d from 3 Oct: $25.83,
$4.77, $64.58, $38.38; 30d from 10 Sep: $24.67, $11.72, $111, $51.15)
and asked two questions. The human chose:

1. **UNIT COSTS: cost within the range.** On day d of the range, the
   spend from the range's first day to d over the units delivered from
   the range's first day to d (the hours line: measuredUSD over model
   hours in the same span); null where a count is zero.
2. **A global `all` choice.** The range toggle becomes
   `[ ] 7d [x] 30d [ ] 90d [ ] all`, and `all` sets every panel on the
   page to the whole record, from the first spend day.

## The rules the foreman set from these words

- **The legend:** one row above each chart's plot, under its title: a
  swatch in the line's data colour and the measure's name, no value
  (`spend  PRs  lines  releases`; `$/PR  $/1k lines  $/release
  $/hour`). The labels at the line ends and their stacking go. On a
  phone the row wraps.
- **TOTALS follows the range:** growth since the range's first day,
  never before the base day: each measure's lifetime cumulative value on
  day d over its lifetime cumulative value on that start day. The
  header names the start (`growth since 10 Sep, log scale`). For 7d on
  9 Oct: ×1.13 spend, ×1.14 PRs, ×1.59 lines, ×1.21 releases; 30d:
  ×2.93, ×3.59, ×8.75, ×2.19; 90d and `all`: since 3 Sep, ×8.81,
  ×9.04, ×26.20, ×4.12.
- **UNIT COSTS follows the range** by rule 1; its x-axis starts on the
  range's first day (never before the first spend day).
- **The note** on missing early spend prints only when the range
  reaches a day before the base day.
- **The data:** the page keeps reading the whole lifetime once at load
  and every five minutes, and a toggle change only recomputes; no
  request on a toggle for these charts.
- **The tooltip** keeps its shape (day, then one row per line).
