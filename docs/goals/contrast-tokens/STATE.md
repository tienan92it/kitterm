# STATE: contrast-tokens

- Status: active
- Round: 0 of 3 in this budget (second budget)
- Rounds total: 2
- Last floor: green (2026-09-10, round 2 after)
- Updated: 2026-09-11, the human ruled and the goal continues

## Queue

1. `open-the-elevation` (capability 3, rewritten by the ruling)
2. `delete-known-below` (capability 4, was capability 3)

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

## Direction

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

Round 3: `open-the-elevation`. Lower the lift on `--ui-surface`,
`--ui-surface-2`, `--ui-hover` and `--ui-active`, and raise the
`.pane-close` opacity, so the pairs the muted tokens cannot reach clear
4.5:1. The measured target is the 178 entries over 24 pairs that
`rounds/002.md` names. Photograph before and after on at least
`github-dark` and `solarized-dark` and stop for the human, because the
ruling changes how every page looks and the human has not seen it yet.

Round 4 then deletes `KNOWN_BELOW` and its mechanism, which was
capability 3 and is now the last item.
