# STATE: cost-per-round

- Status: active
- Round: 0 of 3 in this budget (second budget)
- Rounds total: 4
- Last floor: green (2026-09-16, round 4 after the foreman's command: swift test 726, bench p95 2.57 ms, Linux green)
- Updated: 2026-09-25, resumed for one round on the human's word

## Queue

1. `the-ledger-prints-api-time`. The text ledger of `kitterm goal cost`
   prints the bill's `totalAPIDuration` in an `api` column beside
   `wall`, per round and in the goal's total, a dash where a round has
   no bill. `--json` is unchanged.

## Failures

None.

## Proposals waiting on the human

None. The API-time proposal is queued as round 5.

2026-09-25, the foreman closed the `Result:` half: `facts.md` carries
the rule (PR #151).

## Done

- `keep-the-join` (capability 1), round 1, `b39ba30`. See
  `rounds/001.md`. Every hook records the Claude Code session id and
  transcript path on the session, the archive keeps them, and the row
  exposes `agentSessionId` and `agentTranscript`.
- `read-the-bill` (capability 2), round 2, `0476af1`. See
  `rounds/002.md`. `GET /api/sessions/<id>/cost` reads the transcript's
  last line in one 64 KiB `pread` off the event loop. The foreman read a
  real bill through it: fleet-catch-up round 1 cost $7.14.
- `the-bill-in-the-record` (capability 3), round 3, `3c26f67` plus the
  foreman's commit. See `rounds/003.md`, which carries the first
  `Cost:` line: $4.74 · 3331k in (97% cached) · 36k out · 0h 10m.
- `the-ledger` (capability 4), round 4, `100a760` plus the foreman's
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

Round 5: `the-ledger-prints-api-time`.
