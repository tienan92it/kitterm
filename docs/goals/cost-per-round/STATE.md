# STATE: cost-per-round

- Status: active
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-09-15, round 3 after the foreman's command: swift test 714)
- Updated: 2026-09-15, round 3 closed

## Queue

1. `the-ledger` (capability 4)

## Failures

None.

## Proposals waiting on the human

- None that block. Round 3 found that Collect tells the foreman to read
  the live cost route for a bill that exists only after the session is
  archived. The foreman folds the fix into round 4 rather than wait:
  archive, then read the bill through the archive's transcript path.

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

Round 4: `the-ledger` from `plan.md` row 4, the last capability. `kitterm
goal cost <root> [<slug>]` reads every round record's `Sessions:` and
`Cost:` lines and prints per goal and per round: dollars, tokens by kind,
cache-read share, wall-clock, tests added, files changed, decision, and
the merged PR. Totals per goal; rounds without a `Cost:` line print a
dash and a footer counts them. `--json` gives the same.

Two things from round 3. The bill exists only after the session is
archived, so the ledger reads it through the archive's `agentTranscript`
path, and round 4 also serves `GET /api/archives/<id>/cost` so the
foreman can read a bill at collect time after archiving; the Collect
sentence in `LOOP.md` then changes to "archive, then read", delivered as
a command. And `totalLinesAdded` reads 0 on rounds that edit through
heredocs, so files changed come from `git diff`, as the plan says.

The budget is spent after round 4, so the goal closes or waits then.
