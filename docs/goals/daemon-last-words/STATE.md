# STATE: daemon-last-words

- Status: active
- Round: 2 of 3 in this budget (first budget; rounds 1 and 2 done)
- Rounds total: 2
- Last floor: green (2026-09-10, round 2 after)
- Updated: 2026-09-10

## Queue

1. `say-it-on-the-page` (capability 3)

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
- `report-the-previous-run` (capability 2), round 2, `884be00`. See
  `rounds/002.md`.

## Next action

Round 3: `say-it-on-the-page` from `plan.md` row 3; proof: corpus request
`01-unrecorded-restart` at 1200 px and 390 px, and a vitest over the
model function. It needs only three keys from the event capability 2
emits: `previous`, `previousAliveAt`, `previousSessions`. Show the line
for `previous=unrecorded` only; `clean` and `takeover` show nothing, and
a takeover loses no sessions.
