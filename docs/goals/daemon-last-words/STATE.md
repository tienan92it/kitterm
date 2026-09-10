# STATE: daemon-last-words

- Status: active
- Round: 1 of 3 in this budget (first budget; round 1 done)
- Rounds total: 1
- Last floor: green (2026-09-10, round 1 after)
- Updated: 2026-09-10

## Queue

1. `report-the-previous-run` (capability 2)
2. `say-it-on-the-page` (capability 3)

## Failures

None.

## Proposals waiting on the human

- `plan.md` capability 1: the `restarted` reason has no writer. `kitterm
  restart` reaches the daemon as the same `SIGTERM` that `kitterm stop`
  sends, so the CLI would have to write its intent before signalling.
  Both are clean ends, so capability 2 loses nothing by the gap. Decide
  before capability 2 reads the file. See `rounds/001.md`.

## Done

- `record-how-a-run-ends` (capability 1), round 1, `f76ec7c`. See
  `rounds/001.md`.

## Next action

Merge round 1, then round 2: `report-the-previous-run` from `plan.md`
row 2; proof: a scratch daemon killed with `SIGKILL` then started, whose
log line and `daemon.started` event carry `unrecorded`, and `clean` after
a `kitterm stop`. It reads the record `beginRun` already returns.
