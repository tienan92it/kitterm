# Plan: proxy-is-a-boundary

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift | `swift test` | exit 0 |
| Daemon | `swift test --filter KittermDaemonTests` | exit 0 |
| Linux | the `facts.md` docker pipe | `Build complete`, 0 errors |
| Bench | `swift run KittermBench interactive-echo` | p95 under 50 ms |

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **The measurement, on the record again.** Drive the three configurations of `goal.md` over real sockets against a scratch daemon and record what each answers today, before any change. No product change this round. | A test per configuration, each asserting today's behaviour, the unsafe one asserting the 200 it currently gives. The round record quotes the three responses. |
| 2 | **The daemon refuses the combination.** `--lan` with no `--trusted-host` fails to start, naming both flags and the fix. The other two configurations are untouched. Capability 1's unsafe test flips to assert the refusal; the other two must not change. | `swift test`; the three tests; the refusal's exact words in the record and in `AGENTS.md`. |

Capability 1 first, and it changes no product code: a hole that is only
described is a hole that can come back. Capability 2 then has a test
that fails before it and passes after.
