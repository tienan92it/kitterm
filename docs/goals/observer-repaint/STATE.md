# STATE: observer-repaint

- Status: waiting
- Round: 0 of 3 in this budget (first budget)
- Rounds total: 0
- Last floor: green (2026-10-30, not yet run; base CI green on 7d5dcb8)
- Updated: 2026-10-30

## Queue

1. `repaint-mechanism`, decide between a SIGWINCH nudge and a replay from the last alt-screen-enter; record it in an ADR (capability 1)
2. `repaint-on-attach`, apply the chosen mechanism when a client attaches to an alt-screen session (capability 2)
3. `guard-controller`, protect the controller and the normal-screen replay (capability 3)

## Failures

None.

## Proposals waiting on the human

None.

## Done

None.

## Next action

The foreman drafted `goal.md` and `plan.md` from its diagnosis of the
garbled-join bug. The human reviews them, edits as needed, and adds the
approved request under `corpus/`. Then the human sets `Status: active`
to run round 1 (`repaint-mechanism`), whose first product is an ADR the
human accepts. No round runs while this stays `waiting`.
