# STATE: command-failed-event

- Status: done
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-28, round 2 after: swift test 923, Linux build)
- Updated: 2026-09-28, round 2 closed, done

## Queue

Empty. Both capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `the-contract-written-down` (capability 2), round 2, `a02f57a`. See
  `rounds/002.md`. `AGENTS.md`, the MCP description and the foreman
  skill name the event.
- `the-event` (capability 1), round 1, `ade5e7e`. See `rounds/001.md`.
  The feed carries `command.failed {index, exit, command?}` for a
  failed command in an orchestrated session; the review caught a
  duplicate-mark defect before the merge.

## Direction

2026-09-28: the human chose this goal from the foreman's plan (the
decision table after v0.33.0). The foreman drafted `goal.md` and
`plan.md`; the status stays `waiting` until the human approves them by
merging this package, then the foreman sets it `active`. The human
merged PR #163 on 2026-09-28.

## Next action

None. The five completion conditions of `goal.md` hold on the branch.
Merge the PR and release; a foreman sees `command.failed` once the
daemon runs the new binary. To reopen, set `Status: active` with a new
queue.
