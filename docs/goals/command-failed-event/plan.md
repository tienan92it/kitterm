# Plan: command-failed-event

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift | `swift test` | exit 0, 909 tests at the start |
| Linux build | the `facts.md` docker pipe | `Build complete`, 0 errors |
| Bench | `swift run KittermBench interactive-echo --port <scratch>` against a scratch daemon | p95 under 50 ms |

The mark that ends a command lands on the event loop
(`SessionRegistryObserver.commandEnded`), so the bench is a real gate:
the append must not add work to the output path.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **The event.** On a non-zero `commandEnd` in an orchestrated session, append `command.failed {index, exit, command?}` for that session. The index is the one `/commands` gives the same command. | A test over a real shell: an orchestrated session runs `false`, the feed carries the event with the right index and exit; `true` and a browser session's `false` append nothing; the bench. |
| 2 | **The contract, written down.** `AGENTS.md` lists the type; the MCP `wait_for_events` description names it; the foreman skill's "Monitor" section, in `examples/foreman/foreman-loop.md` and its embedded copy `ForemanSkills`, says to relay it at once for a crew session and to read the command's output. | The golden test for `ForemanSkills`; `GoalsLayoutDocsTests` and the sentence checks green; the three texts in the note. |

Capability 1 first: the text describes an event that exists.
