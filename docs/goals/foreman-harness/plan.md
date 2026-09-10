# Plan

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Daemon and CLI tests | `swift test` | exit 0 |
| I/O latency | `swift run KittermBench interactive-echo` | p95 under 50 ms |
| Web build and tests | `pnpm build && pnpm test` in `Web/terminal` | exit 0 |
| Linux build | `swift build` in `swift:6.1`, alone, on a round that touches `Sources/` | exit 0 |

Run one heavy build at a time (`facts.md`, Toolchain).

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **`send_input` carries a key.** The bridge stops dropping the escape byte, or takes a `keys` argument naming the common keys (`up`, `down`, `enter`, `escape`, `ctrl-c`). Whichever shape, a foreman answers a trust dialog with the toolset alone. | A test that an escape sequence for the Down arrow reaches the pane as three bytes, read back from the session's output; the schema golden updated. |
| 2 | **The skill drops the workaround.** `examples/foreman/foreman-loop.md` answers the trust dialog with the toolset; `review-crew` and `triage` keep their shared text identical; `kitterm skills install` carries all three. | `ForemanSkillsTests` golden; no `curl` in the trust-dialog step; a live check that the installed skill answers a real dialog. |
| 3 | **Nearest `.git` wins.** `ProjectStore.resolve` walks for `.git` before it takes a registered prefix, so a checkout under a registered parent is its own project. A registered root still names and configures the project it points at. | The resolution table gains the nested case; the existing rows still pass; `kitterm project list` unchanged. |
| 4 | **The four rules are written once.** A killed attempt does not spend the budget and is recorded as such; a test that pins a layout `goal.md` replaces is Propose; `resumed-from` is an archive id or the pane's previous id; the round's note goes out before the floor and is updated after. In `docs/goals/LOOP.md`, `examples/goals/LOOP.md`, and the skill. | `GoalsLayoutDocsTests` extended to fail when the three files disagree on a rule's presence; the templates' golden test. |

Capabilities 1 and 2 are one thread; 2 depends on 1. Capabilities 3 and 4
are independent of both and of each other.
