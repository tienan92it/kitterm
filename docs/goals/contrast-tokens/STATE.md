# STATE: contrast-tokens

- Status: waiting
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-10, round 2 after)
- Updated: 2026-09-10, round 2 closed; the goal needs a ruling

## Queue

1. `delete-known-below` (capability 3). Blocked: it requires
   `KNOWN_BELOW` to be empty, and 178 entries over 24 pairs are out of
   reach of the tokens the goal allows. It needs the ruling below first.

## Failures

None.

## Proposals waiting on the human

- **`goal.md` is Frozen and its completion condition 1 cannot hold with
  the tokens the goal allows.** Round 2 raised both muted steps as far as
  they go and cleared 95 of the 273 entries. 178 remain, over 24 of the
  45 pairs. The reason is structural, not tuning: the surfaces are lifted
  from `--ui-bg` toward `--ui-lift`, so on a theme whose foreground sits
  near the floor, no colour dimmer than the foreground clears a lifted
  surface. Round 2 proved the limit by setting both tokens to the
  foreground itself: 32 cases still fail.

  Round 1's count of what capability 2 could reach was wrong. It said 10
  pairs were out of reach; the real number is 24. Trust round 2's count.

  Three ways out, and the human picks one:

  1. **Open the elevation tokens.** Let a round change what lifts
     `--ui-surface`, `--ui-surface-2`, `--ui-hover` and `--ui-active` off
     `--ui-bg`, and the `.pane-close` opacity of 0.55 at
     `styles.css:469`. These are the levers that actually eat the
     contrast. This is the only route that can empty `KNOWN_BELOW`, and
     it changes how every page looks.
  2. **Accept the 178 and rewrite capability 3.** Keep `KNOWN_BELOW` as a
     recorded, tested debt instead of deleting the mechanism. The page
     then has a measured floor it does not meet, and says so in one
     place. Cheapest, and it keeps the look.
  3. **Narrow the goal.** Drop the file preview's four `--code-*` syntax
     colours and the theme-owned `--ui-accent` and `--ui-danger` pairs
     from scope, and say so in `goal.md`. This cuts the problem but does
     not empty the table either.

  See `rounds/002.md`. This blocks capability 3. Nothing else is queued.

## Done

- `derive-the-pairs` (capability 1), round 1, `94297dd`. See
  `rounds/001.md`.
- `raise-the-mixes` (capability 2), round 2, `64112dc`. See
  `rounds/002.md`. `--ui-text-muted` 66% to 82%, `--ui-text-faint` 46% to
  72%, one rule for all 17 themes, 95 entries dropped. The crew refused
  the rule that clears more, because it puts muted above body text, and
  it photographed both pages.

## Direction

2026-09-10: the human said start. The goal was `waiting` on the foreman's
own scheduling choice, not on a real block.

## Next action

Waiting on the human to pick one of the three ways out above. Capability
3 cannot start until then, and it is the only item left.

The two shipped capabilities stand on their own and can merge now:
`goals/derive-the-pairs-work` at `64112dc` derives every pair the pages
paint and raises both muted steps. Run the review skill before the merge,
as the human requires.

One merge order to keep: this branch rewrites `theme-contrast.test.ts`
whole, and `goals/say-it-on-the-page` adds one hand-written row to the
old shape of that file. Merge this branch first. The derivation finds
that row's pair by itself, so the rebase deletes the hand-written row
rather than moving it.
