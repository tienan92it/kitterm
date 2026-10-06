# The human's request: the REVIEW rows

2026-10-06, in the foreman's pane, after v0.37.0 went live:

> REVIEW row in dashboard looks messy. Let's refactor it

The live row was one paragraph that wrapped over two lines, ran the
ready pull requests and the drafts into one list, broke names inside a
word (`lume-` / `cafe`), and printed CI for the drafts only.

The human chose this layout from three, the same day:

```
REVIEW   3 ready · 2 drafts
  ?  PR #2900  backend / accounts-demo-filter   Filter demo acc…   ready · CI ✓   +120 −8    2h
  ?  PR #1     lume-cafe / product-definition  Product brief f…   ready · CI …    +40 −0    1d
  ?  PR #66    nghenhan-mt5 / chart-replay     Replay source f…   ready · CI ✗   +300 −12   3h
  ▶  2 drafts
```

- The header holds the label and the counts.
- One line per ready pull request, on the tree's own columns: the mark,
  `PR #N` as a link, where it belongs (project / goal, or project / the
  chore's or branch's slug), its title in grey and truncated, its state
  and CI, its size, how long it has waited.
- The drafts fold behind one line, `▶ N drafts`, closed by default, the
  same rows inside.
- With none ready, the header says so, and the drafts line follows.

And the process: one round builds it, then the crew redraws the REVIEW
part of `design/sessions.pen` and the human saves it in Pen once.
