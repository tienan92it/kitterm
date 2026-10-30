# STATE: observer-repaint

- Status: done
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-10-30, round 1; swift test 1411/0, PR #210 CI on ea9f06f)
- Updated: 2026-10-30

## Queue

None.

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `repaint-on-attach`, round 1, PR #210. See `rounds/001.md`. The daemon
  nudges the PTY window size on attach (`PtySession.nudgeWindowSize`) so a
  joined full-screen program repaints; ADR 0006.
- `guard-controller`, round 1, PR #210. Folded into round 1: the test
  proves the controller keeps the held size after two joins and a
  normal-screen shell gets no nudge (completion conditions 2 and 3).

## Next action

None. The completion condition in `goal.md` holds: a join repaints, a
second join leaves the held size, and a normal-screen shell is untouched,
all proven by `rounds/001.md`'s test and a browser join of a live `claude`.
The human merges PR #210, which accepts ADR 0006. Reopen with
`Status: active` and a new queue to harden further.
