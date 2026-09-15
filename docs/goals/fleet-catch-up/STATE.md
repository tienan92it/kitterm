# STATE: fleet-catch-up

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-15, round 1 after: vitest 1321 in 34 files)
- Updated: 2026-09-15, round 1 closed

## Queue

1. `each-fact-once` (capability 2)
2. `catch-up-first` (capability 3)
3. `the-terminal-surface` (capability 4)

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `a-row-is-one-line` (capability 1), round 1, `f38dea5`. See
  `rounds/001.md`. A row is dot, name, state, what, since; `pid`,
  `exit 0`, `attached`, the shell, the tags and the root path are gone.

## Direction

2026-09-15: the human asked for a simpler, minimalist, terminal-looking
fleet view that is easy to catch up on, with redundant detail removed.
The foreman researched the page first: `corpus/inventory.md` lists every
element and where it repeats itself, and the two before-images show the
page at 2304 px and 2820 px tall. The plan removes rather than adds, in
four capabilities, and the human sees the images after capabilities 3
and 4 before either merges.

## Next action

Round 2: `each-fact-once` from `plan.md` row 2; proof: a vitest that no
session id appears in both the strip model and the card model, and that
the proposal model yields one item per proposal; the screenshot shows
the four fixture sessions once each. Capability 4 is independent and may
run alongside it, but it touches `sessions.css`, which capability 2 also
touches, so it waits for 2 to land.
