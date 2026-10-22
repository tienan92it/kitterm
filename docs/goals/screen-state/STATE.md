# STATE: screen-state

- Status: waiting
- Round: 1 of 1 in this budget (second budget)
- Rounds total: 4
- Last floor: green (2026-10-22, round 4 after: swift test 1344, PR CI on 40d045b)
- Updated: 2026-10-22, round 4 done; the capture waits for the human's word and a re-measure

## Queue

None.

## Failures

None.

## Proposals waiting on the human

None. 2026-10-22: the human chose no Clef and a local capture of
`unknown` screens (`corpus/02-clef-decision.md`).

## Done

- `unknown-capture`, round 4, PR #200. See `rounds/004.md`. An opt-in
  local capture of `unknown` screens.
- `screen-count`, round 3, PR #187. See `rounds/003.md`. Each answer is
  counted in `~/.kitterm/screen-state.log`, `kitterm screen-state stats`
  prints the count, and the skill calls `screen_state` first.
- `screen-rules`, round 2, PR #187. See `rounds/002.md`. The MCP tool
  `screen_state` answers a pane's state from rules, with the rule and
  the line.
- `screen-fixtures`, round 1, PR #187. See `rounds/001.md`. 11 real
  screens of Claude Code 2.1.292 cover the eight states.

## Next action

The human merges PR #200; the capture stays off until the human turns
it on (`kitterm screen-state capture on`). On or after 2026-11-05, the
foreman runs `kitterm screen-state stats --days 14` and `samples`, and
proposes the missing rules as a round.
