# STATE: foreman-flow

- Status: waiting
- Round: 0 of 3 in this budget (first budget)
- Rounds total: 0
- Last floor: green (2026-09-29, main at 0227af8: swift test 931, ci.yml green)
- Updated: 2026-09-29, written by the foreman on the human's word

## Queue

1. `the-pr-opens-first` (capability 1).
2. `the-dashboard-shows-the-open-pr` (capability 2).
3. `the-ci-is-the-second-floor` (capability 3).
4. `the-bookkeeping-is-a-command` (capability 4).

## Failures

None.

## Proposals waiting on the human

- `plan.md`, capability 4: one file per chore under `docs/goals/chores/`,
  or the chore's line appended after its merge. The foreman recommends one
  file per chore.

## Done

None.

## Direction

2026-09-29: the human chose "fewer interruptions" and "faster rounds", and
set a rule: every goal and chore opens its PR at the start, and the
dashboard shows it while the work runs. The foreman measured the rounds of
2026-09-25 to 2026-09-28 first (`corpus/01-findings-2026-09-28.md`). This
package is its own first draft PR, #175, opened before it was written. The
goal stays `waiting` until the human approves the package by merging it.

## Next action

Waits on the human: review PR #175, answer the `CHORES.md` question, and
merge. Then round 1: `the-pr-opens-first`, on a new branch with its own
draft PR, which carries the goal's rounds from then on.
