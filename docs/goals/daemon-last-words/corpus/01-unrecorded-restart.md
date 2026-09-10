# Request 01: the page says a run ended without a reason

Approved 2026-09-10. Frozen.

## Fixture

A scratch daemon on its own port and state directory, holding two
sessions. It is killed with `kill -9`, then started again on the same
state directory.

## Request

Open `/sessions` on the new run.

## Expected behaviour

One line above the cards: the daemon restarted at the time the previous
run was last alive, and two sessions were lost. Dismissing it hides it
for this run and it does not return on the next poll. A `kitterm stop`
followed by a start shows no line. A `kitterm upgrade --live` shows no
line, and the sessions are still there.

## Expected persistent effects

`~/.kitterm/last-run.json` under the scratch state directory carries the
new run's `pid` and `startedAt`, and no `endedAt` while it runs.
