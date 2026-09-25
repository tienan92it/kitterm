# STATE: cost-per-round

- Status: done
- Round: 1 of 3 in this budget (second budget)
- Rounds total: 5
- Last floor: green (2026-09-25, round 5 after: swift test 895, KittermCLITests 133, Linux build)
- Updated: 2026-09-25, round 5 closed, done

## Queue

Empty. All four capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

- `corpus/01-what-did-that-goal-cost.md`: its ledger table has no `api`
  column since round 5. The corpus is Frozen, so the human re-aligns it.
  See `rounds/005.md`.

2026-09-25, the foreman closed the `Result:` half: `facts.md` carries
the rule (PR #151).

## Done

- `the-ledger-prints-api-time`, round 5, PR #160. See `rounds/005.md`.
  The text ledger prints `api` beside `wall`: 12m17 of API time in the
  16h17 overnight round.
- `keep-the-join` (capability 1), round 1, `b39ba30`, PR #107. See
  `rounds/001.md`. Every hook records the Claude Code session id and
  transcript path on the session, the archive keeps them, and the row
  exposes `agentSessionId` and `agentTranscript`.
- `read-the-bill` (capability 2), round 2, `0476af1`, PR #110. See
  `rounds/002.md`. `GET /api/sessions/<id>/cost` reads the transcript's
  last line in one 64 KiB `pread` off the event loop. The foreman read a
  real bill through it: fleet-catch-up round 1 cost $7.14.
- `the-bill-in-the-record` (capability 3), round 3, `3c26f67`, PR #111 plus the
  foreman's commit. See `rounds/003.md`, which carries the first
  `Cost:` line: $4.74 · 3331k in (97% cached) · 36k out · 0h 10m.
- `the-ledger` (capability 4), round 4, `100a760`, PR #113 plus the foreman's
  commit. See `rounds/004.md`. `kitterm goal cost` prints the ledger from
  the archive's transcript or the record's line; Collect now reads
  "archive, then read"; the corpus table was re-aligned to match.

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

None. Merge the round's PR. To reopen, set `Status: active` with a new
budget and queue.
