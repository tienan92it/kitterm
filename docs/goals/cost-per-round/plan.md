# Plan

The initial floor and the expected capability order for the goal in
`goal.md`. A human owns this file. A foreman proposes a change to it in a
round record; it does not edit it.

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift tests | `swift test` | exit 0, 699 tests at the start |
| Web | `Web/terminal: tsc --noEmit && vite build && vitest run` | exit 0 |
| Bench | `swift run KittermBench interactive-echo` | p95 under 50 ms |
| Linux build | the `facts.md` pipe into `swift:6.1` | `Build complete`, 0 errors |

This goal touches the hook path and the archive, so the bench is a real
gate. The Linux build caught a `Sendable` error in each of the last three
rounds that touched `Sources/`, so it runs before every push, not only in
CI.

## What the research established

Read `corpus/data-sources.md` before the first round. In short: Claude
Code writes a `cost-state` line as the last line of every transcript,
with `totalCostUSD`, `totalDuration`, `totalAPIDuration`,
`totalLinesAdded`, `totalLinesRemoved`, and `modelUsage` per model with
`inputTokens`, `outputTokens`, `thinkingTokens`, `cacheReadInputTokens`,
`cacheCreationInputTokens` and `costUSD`. Every hook the daemon receives
carries `session_id` and `transcript_path`, and the daemon discards
both. Nothing in `Sources/` knows a token or a dollar. A round record
carries session ids, start and end, base and result, floor counts, files
and decision, and no cost.

## Capability order

Four capabilities. Each ships as one PR. Each names the check that proves
it.

| # | Capability | Proof |
|---|---|---|
| 1 | **The daemon keeps the join.** When a hook arrives, the daemon records the hook's `session_id` and `transcript_path` on the kitterm session, keeps them in the session's archive, and exposes them on the row as `agentSessionId` and `agentTranscript`. A session that runs `claude` twice keeps the latest. Nothing else in the hook path changes. | A route test posts a `Notification` hook and reads the two fields back from `/api/sessions`; archives the session and reads them from the archive; the bench is unchanged. |
| 2 | **Read the bill.** A pure reader in `Sources/KittermDaemon/` parses a transcript's final `cost-state` line into dollars, wall-clock, API time, lines added and removed, and tokens by kind with a per-model breakdown, and tolerates a transcript with no such line, a zeroed one, and a truncated last line. `GET /api/sessions/<id>/cost` serves it, full grade only, 404 when the session has no transcript, and says "no bill yet" rather than zeros when the line is absent. | Unit tests over three real transcript tails checked into `Tests/` as fixtures: one with a bill, one zeroed, one truncated. A route test against a scratch daemon with a fixture transcript. |
| 3 | **The bill in the record.** `LOOP.md`'s round record gains a `- Cost: $D · Nk in (C% cached) · Nk out · Hh Mm` line under the header, and "One round" step 4 tells the foreman to read `/api/sessions/<id>/cost` at collect time and write it. The foreman skill, the template and the embedded copies carry the same rule, and the sentence check from `foreman-harness` round 5 pins it. | `GoalsLayoutDocsTests` gains the rule sentence over all five sources. A round record written by the next round of any goal carries the line. |
| 4 | **The ledger.** `kitterm goal cost <root> [<slug>]` reads every round record's `Sessions:` and `Cost:` lines and the archive's transcript path, and prints per goal and per round: dollars, tokens by kind, cache-read share of input, wall-clock, tests added (parsed from the Floor line's "N new"), files changed, the decision, and the merged PR number when the Result line names one. Totals per goal. Rounds without a `Cost:` line print `—` and a footer counts them. Output is a table, monospace, and `--json` gives the same. | A CLI test over a fixture `docs/goals/` tree with three rounds, one without a bill, asserts the table and the JSON. A run against this repository's real `docs/goals/` prints without error and the foreman reads it into the round record. |

Capability 2 depends on 1 for the transcript path but can be built
against fixtures first. Capability 3 depends on 2. Capability 4 depends
on 3 for the line it parses, and on 1 for the archive's path. A fifth
capability, one number on the goal line of `/sessions`, waits for
`fleet-catch-up` capability 3 to settle that line's shape and is not
written here yet.

## What "return" means here, and what it does not

The ledger's return columns are the ones the repository already records:
merged PRs from the `Result:` line, tests added from the Floor line,
capabilities closed from `STATE.md`. Review findings caught and fixed are
visible as a round whose gap names a review, and the ledger does not
count them; a later goal may. The ledger reports; it does not judge. A
person reads dollars per merged PR and tokens per test and decides
whether a round was worth it.

Token efficiency has one honest measure in the data: the cache-read
share of input. A crew that re-reads the same files gets served from
cache; a prompt that changes its prefix every turn does not. The ledger
prints that share per round so the foreman can see which prompts waste
tokens, and the next goal can act on it.
