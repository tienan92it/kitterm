# STATE: fleet-catch-up

- Status: active
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-15, round 2 after: vitest 1321 in 34 files)
- Updated: 2026-09-15, round 2 closed

## Queue

1. `catch-up-first` (capability 3)
2. `the-terminal-surface` (capability 4)

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

## Direction

2026-09-15: the human asked for a simpler, minimalist, terminal-looking
fleet view that is easy to catch up on, with redundant detail removed.
The foreman researched the page first: `corpus/inventory.md` lists every
element and where it repeats itself, and the two before-images show the
page at 2304 px and 2820 px tall. The plan removes rather than adds, in
four capabilities, and the human sees the images after capabilities 3
and 4 before either merges.

## Next action

Round 3: `catch-up-first` from `plan.md` row 3; proof: corpus request
`01-back-after-lunch` at 390 px with the first screen holding the
needs-you and failed items and the running count, and vitest cases for
the placeholder goal and the done fold. One item from round 2: print the
project on a strip item only when it differs from the session's name.
Capability 4 may run alongside, now that round 2's CSS change has
landed; it touches `sessions.css` and round 3 mostly does not.
