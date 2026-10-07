# STATE: screen-state

- Status: waiting
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-10-07, round 3 after: swift test 1185, PR CI on aa8b831)
- Updated: 2026-10-07, the budget is spent: direction check

## Queue

1. `clef-fallback` (capability 4)

## Failures

None.

## Proposals waiting on the human

- Decide capability 4, the opt-in Clef-flash fallback for `unknown`:
  build it now, or merge capabilities 1 to 3 first and decide with the
  count `kitterm screen-state stats` shows after real use. See
  `rounds/003.md`.

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

Direction check: the human decides capability 4.
