# STATE: fleet-catch-up

- Status: active
- Round: 0 of 3 in this budget (first budget)
- Rounds total: 0
- Last floor: green (2026-09-15, main at e3b6321: vitest 1310 in 34 files)
- Updated: 2026-09-15, planned

## Queue

1. `a-row-is-one-line` (capability 1)
2. `each-fact-once` (capability 2)
3. `catch-up-first` (capability 3)
4. `the-terminal-surface` (capability 4)

## Failures

None.

## Proposals waiting on the human

None.

## Done

None.

## Direction

2026-09-15: the human asked for a simpler, minimalist, terminal-looking
fleet view that is easy to catch up on, with redundant detail removed.
The foreman researched the page first: `corpus/inventory.md` lists every
element and where it repeats itself, and the two before-images show the
page at 2304 px and 2820 px tall. The plan removes rather than adds, in
four capabilities, and the human sees the images after capabilities 3
and 4 before either merges.

## Next action

Round 1: `a-row-is-one-line` from `plan.md` row 1; proof: a vitest over
the row model for four session shapes, and the 390 px screenshot of the
corpus fixture with each row on one or two lines. Capability 4 is
independent and may run alongside it.
