# STATE: screen-state

- Status: waiting
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-10-07, round 3 after: swift test 1185, PR CI on aa8b831)
- Updated: 2026-10-07, direction check: merge capabilities 1 to 3, measure, then decide capability 4

## Queue

1. `clef-fallback` (capability 4)

## Failures

None.

## Proposals waiting on the human

- Decide capability 4 (`clef-fallback`) on or after 2026-10-21, with the
  `unknown` share that `kitterm screen-state stats --days 14` prints.
  2026-10-07: the human chose to merge capabilities 1 to 3 first.

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

The human merges PR #187 (capabilities 1 to 3). On or after 2026-10-21,
the foreman runs `kitterm screen-state stats --days 14` and brings the
`unknown` share to the human, who decides capability 4. The goal stays
`waiting` until then.
