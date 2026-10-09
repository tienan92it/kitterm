# The human's new direction

2026-10-09, in the foreman's pane, after the foreman showed the real
series (all seven counted repositories, spend from the rollup, from
2026-08-10):

> The direction changes. I want 2 charts now based on the real series
> table.
> - One chart that present 4 values: Spend, PRs, Lines, Releases. For big
>   number (Spend, Lines), let's use large number shorthand (k, m, b...).
> - One chart as I described before, include values of $/PR, $/line,
>   $/release, $/hour, but for $/line, let's re-calculate the value of $
>   per 1000 lines

The human's choices, the same day:

1. **Chart 1, TOTALS: each line on its own scale.** Each of the four
   cumulative totals (spend, merged pull requests, merged lines,
   releases) rises from 0 to its own value today, so the four shapes
   compare; the real value sits at each line's right end and in the
   tooltip, in shorthand: `$6.4k`, `240 PRs`, `401k lines`, `69 releases`.

```
TOTALS   since 3 Sep
│                              ╱─ $6.4k spend
│                         ╱────── 240 PRs
│                   ╱──────────── 401k lines
│            ╱────────────────── 69 releases
└───────────────────────────────
 3 Sep                           9 Oct
```

2. **Both charts start at 2026-08-10, as recorded**, the first recorded
   spend day; the August unit costs read low, and the charts say so in a
   note: spend before early September is mostly missing from the record
   (Claude Code's own transcripts of that time were deleted before the
   rollup kept them; not proved).

3. **Chart 2, UNIT COSTS: dollars, not an index.** Four lines on one
   dollar axis: cost per merged pull request, per 1,000 merged lines,
   per release, per hour of model time, each the lifetime spend to day d
   over the lifetime units to day d (the hours line uses `measuredUSD`
   over `apiMs`, as the hours tile does). Today's values: $26.57, $15.90,
   $92.40, $55.32.

This replaces the indexed chart of `00-request.md`. Its other rules hold:
the lines differ by dash in the one data colour, each named at its right
end, the dollar value in a tooltip, the counts summed over the
repositories VALUE counts.

## The series the human saw

| Day | Spend | PRs | Lines | Releases | $/PR | $/1k lines | $/release | $/hour |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 08-10 | $3.05 | 3 | 530 | 2 | $1.02 | $5.75 | $1.53 | $167 |
| 08-16 | $42.73 | 9 | 4,330 | 7 | $4.75 | $9.87 | $6.10 | $107 |
| 08-30 | $294.96 | 22 | 8,734 | 14 | $13.41 | $33.77 | $21.07 | $110 |
| 09-06 | $1,282.07 | 42 | 30,730 | 22 | $30.53 | $41.72 | $58.28 | $70 |
| 09-20 | $4,193.54 | 129 | 104,598 | 36 | $32.51 | $40.09 | $116.49 | $65 |
| 10-08 | $6,375.79 | 240 | 400,666 | 69 | $26.57 | $15.91 | $92.40 | $55 |

## Later the same day: colours, not dashes

The human, after the frames of f9eab1e:

> Use different colors for lines instead of dashed lines

This replaces "the lines differ by dash in the one data colour". It
amends the design foundation, which owned one data colour, on the
human's word: a data palette of four colours for chart lines only
(`--ui-data-1` to `--ui-data-4`), each with a dark and a light value,
each at least 3:1 against the ground in both themes, told apart by a
colour-blind reader, and none equal to or near a colour that carries a
meaning on the page (the accent's working, success, warning, danger,
caution). Each line's label wears its line's colour. The human approves
the four values with the frames.

## Later the same day: TOTALS is growth since 3 Sep on a log axis

The human asked why the TOTALS lines meet at the end (each on its own
scale, every cumulative line ends at the top), saw a log draft, and
said:

> Keep the log TOTALS. I want to measure grow against each other.

The foreman offered rebased growth; the human asked why it starts on
3 Sep and not at the beginning. On 10 Aug the spend record is $3.05, so
a 10 Aug base gives spend ×2,112 against PRs ×81, a multiple of the
missing record, not of growth. On 3 Sep all four measures are complete
($730.96, 27 PRs, 16,643 lines, 17 releases). The human saw two drafts
(from 10 Aug with the base on 3 Sep, and from 3 Sep only) and chose:

> Option 2, apply it

So TOTALS is: each measure divided by its own value on 2026-09-03, on a
log axis (×1, ×2, ×5, ×10, ×20, ×50), from 3 Sep to today; every line
starts at ×1; the end label is the multiple and the measure
(`×26.2 lines`, `×9.0 PRs`, `×8.8 spend`, `×4.1 releases`), and labels
closer than one line height stack instead of overlapping; the tooltip
gives the day's multiples and its real totals in shorthand. The base day
is the first day of full spend records; the foreman proposes that the
page find it as the first day of a run of days with spend, and the human
decides that rule with the build. UNIT COSTS keeps its start, 10 Aug, and
its note.
