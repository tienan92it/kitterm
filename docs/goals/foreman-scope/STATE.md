# STATE: foreman-scope

- Status: active
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-10-01, round 2 after: swift test 997, PR #180 CI green)
- Updated: 2026-10-01, round 2 closed

## Queue

1. `scope-and-upkeep-in-the-texts` (capability 3), PR #180.

## Failures

None.

## Proposals waiting on the human

None.

## Done

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

Round 3: `scope-and-upkeep-in-the-texts`, with the label scheme from
round 2's gap: every foreman takes `crew:foreman` and `scope:<path>`.
