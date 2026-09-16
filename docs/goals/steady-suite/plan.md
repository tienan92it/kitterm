# Plan

The initial floor and the expected capability order for the goal in
`goal.md`. A human owns this file. A foreman proposes a change to it in a
round record; it does not edit it.

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift tests | `swift test` | exit 0, 726 tests at the start |
| Web | `Web/terminal: tsc --noEmit && vite build && vitest run` | exit 0, 1328 at the start |
| Bench | `swift run KittermBench interactive-echo` | p95 under 50 ms |
| Linux build | the `facts.md` pipe into `swift:6.1` | `Build complete`, 0 errors |

## Why this goal exists

The hang has cost three runs in two days: `agent-push` round 2 and
`cost-per-round` round 2 on this machine, and PR #115 on CI, where it
held a four-minute job for thirty-seven minutes. A cancelled run cannot
be rerun, so each occurrence costs a branch refresh. `facts.md` has
recorded it as pre-existing since 2026-09-10 and no round has owned it.

Twelve bare `waitUntilExit()` calls live in seven files:
`PreviousRunReportTests` (3), `PushSubscriptionRouteTests` (2),
`PidAfterBindTests` (2), `LastRunTests` (2), `GoalCostTests` (1),
`LiveTakeoverTests` (1), `PushSendRouteTests` (1).

The clip is on a closed goal's proposal: with a real profile selected,
the card heading reads `kitte…` instead of `kitterm` at 390 px. Round 4
of `fleet-catch-up` tested with a narrower profile name than the real
"local shell".

## Capability order

Two capabilities. Each ships as one PR. Each names the check that proves
it.

| # | Capability | Proof |
|---|---|---|
| 1 | **Every wait has a deadline.** One helper, in a shared test-support file, waits for a process with a timeout and fails the calling test by name when it expires, carrying the process's last output and its pid. Replace all twelve bare calls with it. Pick the deadline from measurement, not taste: time the slowest of these tests three times and say what you chose and why. Add a check that reads the test sources and fails on a bare `waitUntilExit`, so the thirteenth cannot arrive. | A test stalls a subprocess on purpose and asserts the failure arrives inside the deadline naming the test; the source check fails on a planted bare call; `swift test` green and no slower than 726 tests in 100 s. |
| 2 | **The project's name never clips.** At 390 px with the longest bundled profile name, the card heading shows the name in full; the profile control and the count give way first. Decide what gives way and in what order, and say why. | A vitest over the heading model for a long profile name, a long project name, and both; a screenshot of the live page at 390 px with a profile selected, showing `kitterm` in full. |

The two are independent and may run at once: capability 1 is `Tests/`
and capability 2 is `Web/terminal/src/`.
