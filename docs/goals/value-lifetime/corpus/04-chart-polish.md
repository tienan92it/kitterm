# The human's request: chart polish

2026-10-10, in the foreman's pane, after v0.39.0 went live:

> Update line chart UI:
> - Add more space below title TOTALS and UNIT COSTS
> - Chart tooltip look ugly. Text is overflow the tooltip boundary. Let's
>   re-design and fix it
> - TOTALS tooltip just shows the real value of the lines, no need to show
>   the multiple values

The foreman measured the live tooltip the same day: a fixed 260 px box
whose longest line needed 369 px, placed below the chart over the UNIT
COSTS title.

## The redesign the foreman set (on the human's word "re-design")

- A header: the day (`25 Sep`).
- One row per line: a swatch in the line's data colour, the measure's
  name, its value right-aligned. TOTALS rows show the real values only
  (`spend $4.7k`, `PRs 170`, `lines 150k`, `releases 42`), no multiple.
  UNIT COSTS rows show the dollars (`$/PR $26.95`).
- The box fits its content, up to a maximum width, and no text leaves
  it.
- The box sits inside its chart, beside the hovered day; it flips to
  the other side near the right edge, and never covers the other chart
  or its title.
- One more step of the foundation's space scale under each chart title.
