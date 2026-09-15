# STATE: cost-per-round

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-15, round 1 after: swift test 701, bench p95 2.51 ms, Linux green)
- Updated: 2026-09-15, round 1 closed

## Queue

1. `read-the-bill` (capability 2)
2. `the-bill-in-the-record` (capability 3)
3. `the-ledger` (capability 4)

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `keep-the-join` (capability 1), round 1, `b39ba30`. See
  `rounds/001.md`. Every hook records the Claude Code session id and
  transcript path on the session, the archive keeps them, and the row
  exposes `agentSessionId` and `agentTranscript`.

## Direction

2026-09-15: the human asked to measure the return on AI-assisted work
and token efficiency. The foreman researched what exists first:
`corpus/data-sources.md` shows that Claude Code already writes dollars
and tokens by kind into every transcript's last line, that every hook
the daemon receives carries the transcript's path, and that the daemon
discards it. The plan keeps that join, reads the bill, puts it in every
round record, and prints a ledger per goal. Nothing is estimated and no
price table is added.

## Next action

Round 2: `read-the-bill` from `plan.md` row 2; proof: unit tests over
three real transcript tails checked in as fixtures, one with a bill, one
zeroed, one truncated, and a route test for `GET /api/sessions/<id>/cost`
against a scratch daemon. The reader takes the path from
`agentTranscript`. It opens a file, so it must run off the event loop and
the bench must say so.
