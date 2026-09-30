# STATE: foreman-flow

- Status: active
- Round: 0 of 3 in this budget (second budget)
- Rounds total: 3
- Last floor: green (2026-09-29, round 3 after: swift test 944, PR #176 CI green)
- Updated: 2026-09-30, the human said continue

## Queue

1. `the-bookkeeping-is-a-command` (capability 4), PR #176.

## Failures

None.

## Proposals waiting on the human

None. 2026-09-30, the human pruned the `facts.md` line the new floor
replaces ("Run the Linux build as soon as a `Sources/` change compiles").

## Done

- `the-ci-is-the-second-floor` (capability 3), round 3, PR #176. See
  `rounds/003.md`. No local rerun when CI is green; rounds 1 to 3 spent
  48% of their wall time outside the crew, against 56%.
- `the-dashboard-shows-the-open-pr` (capability 2), round 2, PR #176. See
  `rounds/002.md`. A running round's task and PR show under its goal from
  the session's labels, before any merge.
- `the-pr-opens-first` (capability 1), round 1, PR #176. See
  `rounds/001.md`. The draft pull request opens before the crew; crews
  push; `pr` is a reserved label.

## Direction

2026-09-30: continue, a second budget, for capability 4.

2026-09-29: the human chose "fewer interruptions" and "faster rounds", and
set a rule: every goal and chore opens its PR at the start, and the
dashboard shows it while the work runs. The foreman measured the rounds of
2026-09-25 to 2026-09-28 first (`corpus/01-findings-2026-09-28.md`). This
package is its own first draft PR, #175, opened before it was written. The
goal stays `waiting` until the human approves the package by merging it.

## Next action

Round 4: `the-bookkeeping-is-a-command`.
