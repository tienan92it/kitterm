# STATE: screen-state

- Status: active
- Round: 0 of 1 in this budget (second budget)
- Rounds total: 3
- Last floor: green (2026-10-07, round 3 after: swift test 1185, PR CI on aa8b831)
- Updated: 2026-10-22, the human decided capability 4: no Clef, capture unknowns locally (`corpus/02-clef-decision.md`)

## Queue

1. `unknown-capture` (capability 5)

## Failures

None.

## Proposals waiting on the human

None. 2026-10-22: the human chose no Clef and a local capture of
`unknown` screens (`corpus/02-clef-decision.md`).

## Done

- `screen-count`, round 3, PR #187. See `rounds/003.md`. Each answer is
  counted in `~/.kitterm/screen-state.log`, `kitterm screen-state stats`
  prints the count, and the skill calls `screen_state` first.
- `screen-rules`, round 2, PR #187. See `rounds/002.md`. The MCP tool
  `screen_state` answers a pane's state from rules, with the rule and
  the line.
- `screen-fixtures`, round 1, PR #187. See `rounds/001.md`. 11 real
  screens of Claude Code 2.1.292 cover the eight states.

## Next action

Round 4: `unknown-capture` from `plan.md` row 5. Then, on or after
2026-11-05, re-measure with the samples and write the missing rules.
