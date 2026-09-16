# STATE: fleet-catch-up

- Status: done
- Round: 4 of 3 in this budget (first budget)
- Rounds total: 4
- Last floor: green (2026-09-15, round 4 after: vitest 1214 in 35 files)
- Updated: 2026-09-15, done

## Queue

Empty. All four capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

- One defect seen on the live daemon after v0.29.0, not in the fixture:
  when a project has a profile, the card's heading line holds the name,
  the profile select and `[new]`, and at 390 px the **name** clips
  (`kitte…`, `nghenhan-m…`). Round 4 tested with one profile and found
  the tally clipped first; the real profile name "local shell" is wider.
  The name must never clip: the select should shrink or drop to its own
  line first. One round.

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
- `the-terminal-surface` (capability 4), round 4, `10309d0`. See
  `rounds/004.md`. Monospace, hairline sections, bracketed buttons, four
  gutter glyphs, no pill, shadow, tint or transition. 390 px height 1336.

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

None. The goal is done. All five completion conditions hold:

1. Corpus request `01-back-after-lunch` passes at 390 px: the first
   screen holds every needs-input session, every failed session, and the
   count line, with nothing above them but the title, measured in the
   page at 425 px of 844.
2. No fact appears twice. A strip session is not a row; a proposal
   appears once, at the top, from `STATE.md`'s count; the slug, the
   record link and the round counter each appear once or not at all.
3. A row is name, state, what, since. `pid`, `exit 0`, `attached`, the
   shell name and the root path are gone.
4. `sessions.css` has no `border-radius` above 2 px, no `box-shadow` but
   a hairline, no `color-mix` behind text, no `transition`, pinned by
   `sessions-css.test.ts`.
5. `main` is green after the merge.

The phone page went from 2820 px to 1336 px across four rounds, at a
total cost of $35.79, and gained nothing. To reopen, set
`Status: active` with a new budget and queue.
