# STATE: foreman-scope

- Status: done
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-10-01, round 3 after: swift test 1005, PR #180 CI green)
- Updated: 2026-10-01, round 3 closed, done; PR #180 ready

## Queue

Empty. All three capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `scope-and-upkeep-in-the-texts` (capability 3), round 3, PR #180. See
  `rounds/003.md`. One foreman per scope, the start step and the upkeep
  step are in the skill and `LOOP.md`; `scope` is a reserved label.
- `the-catch-up` (capability 2), round 2, PR #180. See `rounds/002.md`.
  `kitterm foreman catch-up` prints one scope's handover and nothing
  from another scope.
- `the-check` (capability 1), round 1, PR #180. See `rounds/001.md`.
  `kitterm project init --refresh --check <root>` prints `current`,
  `behind` or `edited` and writes nothing.

## Direction

2026-09-30: the human asked that a foreman manage the projects in its
scope, and that a new foreman sync up with the work of the one before it.
The foreman wrote the two handovers of 2026-09-25 down first
(`corpus/01-two-handovers.md`). This package's draft PR, #179, opened
before it was written. The goal stays `waiting` until the human merges it. The human merged
PR #179 on 2026-10-01.

## Next action

None. The five completion conditions hold on PR #180. After the human
merges it: release, `kitterm skills install`, and relabel each foreman's
pane `crew:foreman` with `scope:<its workspace>`. The NgheNhanTrading
foreman then runs the start and upkeep steps in its own scope. To
reopen, set `Status: active` with a new queue.
