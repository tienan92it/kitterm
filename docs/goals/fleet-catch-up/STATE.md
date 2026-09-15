# STATE: fleet-catch-up

- Status: active
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-09-15, round 3 after: vitest 1328 in 34 files)
- Updated: 2026-09-15, round 3 closed

## Queue

1. `the-terminal-surface` (capability 4)

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `a-row-is-one-line` (capability 1), round 1, `f38dea5`. See
  `rounds/001.md`. A row is dot, name, state, what, since; `pid`,
  `exit 0`, `attached`, the shell, the tags and the root path are gone.
- `each-fact-once` (capability 2), round 2, `508c8df`. See
  `rounds/002.md`. A strip session is not a row; the card counts only
  what it lists; the proposals count reads from `STATE.md` and shows
  once at the top; the sub-headers and the chip are gone.
- `catch-up-first` (capability 3), round 3, `96bd091`. See
  `rounds/003.md`. The first screen at 390 px holds every attention
  item and the count line with 419 px to spare; template goals read "not
  written yet"; done goals fold; the tools sit below the projects.

## Direction

2026-09-15: the human said to run these on their own and not to ask
again, so the foreman merges each round on a green floor and a read
image, and shows the human the before-and-after in the report rather
than waiting on them. That overrides the plan's line about seeing images
before a merge.

2026-09-15: the human asked for a simpler, minimalist, terminal-looking
fleet view that is easy to catch up on, with redundant detail removed.
The foreman researched the page first: `corpus/inventory.md` lists every
element and where it repeats itself, and the two before-images show the
page at 2304 px and 2820 px tall. The plan removes rather than adds, in
four capabilities, and the human sees the images after capabilities 3
and 4 before either merges.

## Next action

Round 4: `the-terminal-surface` from `plan.md` row 4, the last
capability. Remove every `border-radius` above 2 px, every `box-shadow`
that is not a hairline, every `color-mix` tint behind text, every
`transition`, and the dot's glow; cards become hairline sections; chips
become bracketed words; strip items become lines with a gutter mark.
Round 3 adds one item: the card head still prints the root path and the
"New session" button on their own lines, about 80 px per card on a
phone; fold them into the card's one heading line. Proof: a vitest that
reads `sessions.css` with `node:fs` and asserts the four absences; the
ratchet unchanged and green; before and after on `github-dark` and
`solarized-dark` at both widths. Then `AGENTS.md`'s fleet-view paragraph
needs rewriting for the new shape, which round 4 may do.
