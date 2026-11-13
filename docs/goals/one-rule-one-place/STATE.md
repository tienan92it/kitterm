# STATE: one-rule-one-place

- Status: done
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-11-13, round 3)
- Updated: 2026-11-13

## Queue

None.

## Failures

None.

## Proposals waiting on the human

- `LOOP.md`, "Budget": the limit is now two corrections per round, from
  one. Say "one" to restore the old limit; the fresh session stays.
- Before a crew starts with the settings file: upgrade the installed
  `kitterm` (v0.49.0 has no `round guard`), then run
  `kitterm skills install`. Until then every Bash call of such a crew
  is refused.
- `ScreenState` rules beyond the two fixed here wait on the
  `screen-state` re-measure, due since 2026-11-05.

## Done

- `each-rule-has-one-home`, round 1, `31f2a0e`, PR #217. See `rounds/001.md`.
  14,298 words to 11,489; a test of 25 stale phrases.
- `deny-rules-and-stalls`, round 2, `c6a6c76`, PR #217. See `rounds/002.md`.
  Deny rules and a guard for crew sessions; a stall rule on four facts.
- `review-plan-overlap`, round 3, `49494c8`, PR #217. See `rounds/003.md`.
  Four rules, three flags, and a guard that reads shell forms.

## Next action

None. Merge PR #217. It ends the ten changes of
`docs/goals/lean-context/corpus/00-request.md`. To reopen, set
`Status: active` with a new queue.
