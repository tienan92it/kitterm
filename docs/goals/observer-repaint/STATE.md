# STATE: observer-repaint

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 0
- Last floor: green (2026-10-30, base is merged PR #209 on ed17302)
- Updated: 2026-10-30

## Queue

1. `repaint-on-attach`, the daemon nudges the PTY window size on a new attach so a joined full-screen program repaints; record the decision in ADR 0006 (capability 1)
2. `guard-controller`, protect the controller and the normal-screen replay (capability 3)

## Failures

None.

## Proposals waiting on the human

None.

## Done

None.

## Next action

Round 1: `repaint-on-attach`. The human chose the SIGWINCH nudge over a
replay-from-alt-screen-enter (`corpus/00-request.md`). The crew implements
the nudge on the attach path, adds a daemon test, and drafts ADR 0006; the
foreman proposes the ADR for the human to commit (`docs/adr/` is Propose
tier). The capability touches `PtySession.swift` and the attach handler, so
the round carries a review session.
