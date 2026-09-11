# STATE: contrast-tokens

- Status: active
- Round: 0 of 3 in this budget (third budget)
- Rounds total: 4
- Last floor: green (2026-09-11, round 4 after)
- Updated: 2026-09-11, the human ruled; the goal continues

## Queue

1. `ratchet-known-below` (capability 4, rewritten by the ruling)

## Failures

None.

## Proposals waiting on the human

None. The human ruled on 2026-09-11; see "Direction".

## Done

- `derive-the-pairs` (capability 1), round 1, `94297dd`. See
  `rounds/001.md`.
- `raise-the-mixes` (capability 2), round 2, `64112dc`. See
  `rounds/002.md`. `--ui-text-muted` 66% to 82%, `--ui-text-faint` 46% to
  72%, one rule for all 17 themes, 95 entries dropped. The crew refused
  the rule that clears more, because it puts muted above body text, and
  it photographed both pages.
- `open-the-elevation` (capability 3), round 3, `fae03f8`. See
  `rounds/003.md`. The four surface tokens drop from 7/12/17/23 percent
  of `--ui-lift` to 3/6/9/12, and `.pane-close` stops fading. 44 entries
  dropped and one whole pair is gone. Cards sit closer to the page and
  keep their border.
- `keep-the-cues` (round 4, the repair), `1c01d28`. See `rounds/004.md`.
  A review before the merge found three elements that lost their only
  cue to the elevation drop. `.quiet` and `.more` take an inset
  `--ui-border` ring on hover; `.selection-action:active` takes an inset
  `--ui-accent` ring, because `--ui-border` measured no better than what
  the press had lost.

## Direction

2026-09-11: the human ruled on the contradiction round 3 exposed.
Completion condition 3 required `KNOWN_BELOW` to be empty, and no lever
the goal allows can reach zero: 134 combinations remain, and most are a
theme's own foreground on its own background, which `goal.md` excludes
from change. `solarized-dark` reads 4.32 there.

**The list becomes a ratchet.** It can shrink and it cannot grow. A pair
that is not already listed and fails the floor fails the build. A listed
pair that starts passing fails the build until its entry goes. That keeps
the promise the goal exists for, which is that no new unreadable text
ships, without demanding a number the themes make impossible.

Completion conditions 1 and 3 are amended to say so, and capability 4 is
rewritten from "delete the escape hatch" to "make it a ratchet, and
shorten it once more".

2026-09-11: round 3 ran the ruling and reported that the lever cannot
reach the goal. That is not a failed round; it is the measurement the
ruling lacked. The goal returns to the human.

2026-09-11: the human chose to **open the elevation tokens**, which was
option 1 of the three round 2 put forward. Round 2 showed that 178
`KNOWN_BELOW` entries over 24 pairs are out of reach of
`--ui-text-muted` and `--ui-text-faint`, because the surfaces are lifted
off `--ui-bg` and no colour dimmer than the foreground clears a lifted
surface. Elevation is the cause, so elevation is the lever. `goal.md`'s
"No redesign" exclusion now names the elevation tokens and the
`.pane-close` opacity as permitted. Every other size, weight and layout
still stays. This is the only route that can empty `KNOWN_BELOW`, and its
cost is that every page changes how it looks.

2026-09-10: the human said start. The goal was `waiting` on the foreman's
own scheduling choice, not on a real block.

## Next action

Round 5: `ratchet-known-below` from `plan.md` row 4. Make the list a
ratchet, then open the three opacities round 3 left alone, which
`rounds/003.md` measured as clearing 24 entries. Give every remaining
entry the lever that would clear it, or the note that only a theme's own
colours could.

Proof: a planted new bad pair fails by file, line and selector; a planted
entry that now passes fails with "drop this entry"; the 24 opacity
entries are gone; every remaining entry carries its blocker.
