# STATE: round-commands

- Status: done
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-11-11, round 3)
- Updated: 2026-11-11

## Queue

None.

## Failures

None.

## Proposals waiting on the human

- `LOOP.md`, "Parsed shapes": say that the correction is a
  `## Correction` section whose text does not start with "None". The goal
  `one-rule-one-place` makes the edit.
- `TranscriptBill`: read a bill that a late `assistant` line of the
  same turn follows (`facts.md`, "Foreman", 2026-11-11). Existing tests
  pin "an `assistant` line after the bill makes it stale", so the change
  is outside this goal's charter. A chore, on the human's word.
- `ModelPricing`: add the rates of `claude-fable-5-2`,
  `claude-opus-5-5` and `claude-sonnet-5-5`. Without them the
  `- Foreman:` line and the fleet view's running estimate print no
  dollars for those models. A chore, on the human's word.

## Done

- `corrections-count-when-real`, round 1, `e1a1d78`, PR #216. See
  `rounds/001.md`. 17 "None" corrections no longer count.
- `round-open`, round 2, `190a8e7`, PR #216. See `rounds/002.md`.
  `kitterm round open` with seven tests.
- `round-close`, round 3, `8e74b36`, PR #216. See `rounds/003.md`.
  `kitterm round close` with 11 tests; it closed its own round.

## Next action

None. Merge PR #216; then `one-rule-one-place` starts
(`docs/goals/lean-context/corpus/00-request.md`). To reopen, set
`Status: active` with a new queue.
