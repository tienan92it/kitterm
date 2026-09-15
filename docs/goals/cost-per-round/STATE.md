# STATE: cost-per-round

- Status: active
- Round: 0 of 3 in this budget (first budget)
- Rounds total: 0
- Last floor: green (2026-09-15, main at e3b6321: swift test 699, vitest 1310)
- Updated: 2026-09-15, planned

## Queue

1. `keep-the-join` (capability 1)
2. `read-the-bill` (capability 2)
3. `the-bill-in-the-record` (capability 3)
4. `the-ledger` (capability 4)

## Failures

None.

## Proposals waiting on the human

None.

## Done

None.

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

Round 1: `keep-the-join` from `plan.md` row 1; proof: a route test that
posts a hook and reads `agentSessionId` and `agentTranscript` back from
the row and from the archive, and an unchanged bench. It touches the hook
path, so the Linux build runs before the push.
