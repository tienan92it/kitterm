# Plan

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Daemon and CLI tests | `swift test` | exit 0 |
| I/O latency | `swift run KittermBench interactive-echo` | p95 under 50 ms |
| Web build and tests | `pnpm build && pnpm test` in `Web/terminal` | exit 0 |
| Linux build | `swift build` in `swift:6.1`, alone | exit 0 |
| Repeat | `swift test --filter <suite>` 20 times in a row | 20 of 20 pass |

The repeat check is this goal's own instrument. It belongs to the floor
only while this goal runs. It runs with no artificial load: on
2026-09-09 an eight-core load starved the daemon that hosts the crew,
its launchd agent restarted it, and the round's work was lost
(`facts.md`, Foreman). A race is reproduced by widening its window in a
scratch copy of the test, which proves the mechanism, not by loading the
machine, which only makes the mechanism more likely.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **The paced-input test waits for raw mode.** Replace the `!foregroundIsShell` gate with a wait on the condition the route checks, so the body is typed only once the reader holds the terminal in raw mode. Name the reader in the wait so a future reader change fails loudly. | The failure reproduced first in a scratch copy that widens the window (a slower `stty`), then 20 of 20 runs of `PacedInputTests`. |
| 2 | **The takeover test proves the overlap.** Make the second request provably arrive while the first is pending, or assert only what the two requests guarantee and move the refusal check to a test that controls the timing. | The failure reproduced first in a scratch copy that delays the first handoff, then 20 of 20 runs of `LiveTakeoverTests`. |
| 3 | **The same wait helper is right everywhere.** Audit every use of a "not the shell" or bare-sleep gate in the daemon tests and fix the ones that hold the same race. | The audit listed in the round record; the full suite 20 of 20. |

Capability 3 depends on 1. Capabilities 1 and 2 are independent.
