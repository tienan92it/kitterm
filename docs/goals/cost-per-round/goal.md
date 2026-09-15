# Goal: every round knows what it cost, and the loop knows what it bought

## Objective

A person can ask, of any goal, what it cost in dollars, tokens and
wall-clock, and what it returned in merged pull requests, tests added and
capabilities closed, and get an answer from the repository rather than
from memory. Every round record carries its own bill. A command prints
the ledger per goal and per round, and shows where tokens went: how much
of each round's input was served from cache, how much was re-read, and
how much was output. The numbers come from what Claude Code already
writes, joined to the session the daemon already runs; nothing is
estimated.

## Exclusions

- No price table. Claude Code writes `totalCostUSD` and a per-model
  breakdown into every transcript; this goal reads it and does not
  recompute it.
- No accounting for a human's time. The wall-clock of the crew's session
  is measured; the foreman's and the human's are not.
- No new hook. The four hooks the daemon already receives carry the
  transcript path; this goal keeps what they carry.
- No dashboard change beyond one number on a goal line, and that number
  waits for `fleet-catch-up` capability 3 to settle the goal line's
  shape.
- No change to the round record's other fields, and no rewrite of
  earlier records. Rounds before this goal have no bill and the ledger
  says so.

## Completion condition

All five hold on a build from `main`:

1. Every session that ran `claude` carries the Claude Code session id and
   the path to its transcript, on the session, in its archive, and on
   the API.
2. `GET /api/sessions/<id>/cost` answers, for that session, the dollars,
   the wall-clock, the API time, and the tokens by kind — input, output,
   cache creation, cache read, thinking — read from the transcript's
   final `cost-state` line, with a per-model breakdown; or says plainly
   that the transcript has no bill yet.
3. A round record written after this goal carries a `Cost:` line in its
   header, and `LOOP.md` names the line and where the foreman reads it.
4. `kitterm goal cost <root>` prints the ledger: per goal and per round,
   dollars, tokens by kind, the cache-read share of input, wall-clock,
   tests added, files changed, the decision, and the merged PR when there
   is one; with totals per goal and a line for rounds that predate the
   bill.
5. The floor is green and `main` is green after the merge.

The floor (`swift test`, the web suite, `swift run KittermBench
interactive-echo` under 50 ms p95, and the Linux build) is green at every
step.
