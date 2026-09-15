# STATE: cost-per-round

- Status: active
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-15, round 2 after: swift test 714, bench p95 2.61 ms, Linux green)
- Updated: 2026-09-15, round 2 closed

## Queue

1. `the-bill-in-the-record` (capability 3)
2. `the-ledger` (capability 4)

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `keep-the-join` (capability 1), round 1, `b39ba30`. See
  `rounds/001.md`. Every hook records the Claude Code session id and
  transcript path on the session, the archive keeps them, and the row
  exposes `agentSessionId` and `agentTranscript`.
- `read-the-bill` (capability 2), round 2, `0476af1`. See
  `rounds/002.md`. `GET /api/sessions/<id>/cost` reads the transcript's
  last line in one 64 KiB `pread` off the event loop. The foreman read a
  real bill through it: fleet-catch-up round 1 cost $7.14.

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

Round 3: `the-bill-in-the-record` from `plan.md` row 3. `LOOP.md`'s round
record gains a `- Cost:` line under the header, "One round" step 4 tells
the foreman to read `/api/sessions/<id>/cost` at collect time and write
it, and the skill, the template and the embedded copies carry the same
rule under the sentence check from `foreman-harness` round 5. Proof:
`GoalsLayoutDocsTests` gains the sentence over all five sources.

One fact for capability 4 from round 2's real bill: `totalLinesAdded`
reads 0 on a round that changed four files, because crews edit through
heredocs. Files changed come from `git diff`, not from the bill.

`docs/goals/LOOP.md` is the foreman's file, so round 3 delivers its
change as one command with a scratch-tree proof, the way `foreman-harness`
rounds 4 and 5 did.
