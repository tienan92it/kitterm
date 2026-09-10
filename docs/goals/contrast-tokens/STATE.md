# STATE: contrast-tokens

- Status: waiting
- Round: 2 of 3 in this budget (second budget)
- Rounds total: 4
- Last floor: green (2026-09-11, round 4 after)
- Updated: 2026-09-11, round 4 closed; the goal needs a second ruling

## Queue

1. `delete-known-below` (capability 4). Blocked: it requires
   `KNOWN_BELOW` to be empty, and 134 entries remain. It needs the
   ruling below first.

## Failures

None.

## Proposals waiting on the human

- **The elevation lever is spent, and it could never have emptied the
  table.** Round 3 lowered all four surface tokens as far as they pay and
  went from 178 entries to 134. It then measured the limit: with all four
  set to `--ui-bg` itself, 136 still fail, which is worse than the rule
  it shipped. Sinking them below `--ui-bg` bottoms out at 115. The
  foreman recommended this lever as "the only route that can empty
  `KNOWN_BELOW`" and that was wrong; see the gap in `rounds/003.md`.

  What blocks the remaining 134: 33 the four surface tokens, because the
  theme's own colours already fail on `--ui-bg`; 32 under
  `--ui-accent-soft`; 24 under the three opacities round 3 did not open;
  19 on `--ui-bg-sunken`; 12 on `--ui-bg`; 11 on the status tints; 3 on
  `--ui-border` used as a fill.

  The human decides two things:

  1. **How much further to go.** The cheapest next step is the other
     three opacities, `.settings-gear` at 0.35 and 0.65 and
     `.keyboard-toggle` at 0.75. That clears all 24 of that group with
     the same one-line change `.pane-close` already took.
     `--ui-accent-soft` is the next largest at 32. Neither empties the
     table.
  2. **Whether `KNOWN_BELOW` is ever meant to reach zero.** Completion
     condition 3 requires it today, and no combination of levers measured
     so far gets there. Either the condition changes, or the goal accepts
     a recorded, tested debt, or the themes' own colours come into scope,
     which `goal.md` excludes.

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

Waiting on the human for the two decisions above. Capability 4 cannot
start until the second one is answered, and it is the only item left.

The three shipped capabilities stand on their own and can merge:
`goals/open-the-elevation` at `1c01d28`, which carries rounds 1 to 4.
The review has run and round 4 closed both of its blocking findings. The page
looks different after this branch, so the human should see the eight
images in `/Users/antran/.claude/jobs/b7a30d73/tmp/ct-round3/`, and the
seven in `ct-round4/`, before it lands.
