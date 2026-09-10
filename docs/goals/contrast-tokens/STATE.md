# STATE: contrast-tokens

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-10, round 1 after)
- Updated: 2026-09-10, round 1 closed

## Queue

1. `raise-the-mixes` (capability 2)
2. `delete-known-below` (capability 3)

## Failures

None.

## Proposals waiting on the human

- `goal.md` is Frozen and its completion condition 1 cannot hold as
  written. Round 1 derived 45 pairs where the hand list had 5, and 39 of
  them fail. Capability 2 may move only `--ui-text-muted` and
  `--ui-text-faint`, so it can reach 29 of the 39. The other ten are
  theme-owned colours the exclusions put out of reach: the file preview's
  four `--code-*` syntax colours on `--ui-bg-sunken`, `--ui-accent` on
  three surfaces, `--ui-danger` on two, and `--ui-text` on `--ui-bg` on
  `synthwave-84` at 4.32, which is that theme's own foreground on its own
  background. Three ways out are in `rounds/001.md` under "The ten pairs".
  This blocks capability 3, which wants `KNOWN_BELOW` empty. It does not
  block capability 2.

## Done

- `derive-the-pairs` (capability 1), round 1, `94297dd`. See
  `rounds/001.md`.

## Direction

2026-09-10: the human said start. The goal was `waiting` on the foreman's
own scheduling choice, not on a real block.

## Next action

Round 2: `raise-the-mixes` from `plan.md` row 2. Change `--ui-text-muted`
and `--ui-text-faint` in `tokens.css` so the 29 reachable pairs pass on
every theme. Prefer one rule that holds for all themes over a per-theme
table. The target list is `KNOWN_BELOW` in `theme-contrast.test.ts`, pair
first with the theme and the ratio. The heavy rows: `--ui-text-faint` on
`--ui-surface` fails on all 17 themes, from 1.61 to 3.50, and on
`--ui-surface` plus `--ui-accent-soft` on all 17, from 1.02 to 2.25.
`--ui-text-muted` fails on 10 to 15 themes on each of `--ui-surface`,
`--ui-surface-2`, `--ui-hover`, `--ui-bg` and the two strip tints.

Round 2 does not need the human's ruling above. Capability 3 does.

One merge order to keep: this branch rewrites `theme-contrast.test.ts`
whole, and `goals/say-it-on-the-page` adds one hand-written row to the
old shape of that file. Merge this branch first. The derivation finds that
row's pair by itself, so the rebase deletes the hand-written row rather
than moving it.
