# Plan

The initial floor and the expected capability order for the goal in
`goal.md`. A human owns this file. A foreman proposes a change to it in a
round record; it does not edit it.

## The floor

The floor holds earned behaviour. It starts green and must stay green. A
red floor makes the regression the next round's job.

| Check | Command | Pass condition |
|---|---|---|
| Swift unit tests | `swift test` | exit 0 |
| Web build | `cd Web/terminal && pnpm build` | exit 0 |
| Web unit tests | `cd Web/terminal && pnpm test` | exit 0 |
| TUI redraw bench | `swift run KittermBench` (TUI-redraw scenario) | reads the full frame, within the noise floor |

Each round adds at least one deterministic check for the behaviour it
closes. A check that exists is frozen (see `LOOP.md`).

## Capability order

3 capabilities. Each ships as one PR. Each names the check that proves it.

| # | Capability | Proof |
|---|---|---|
| 1 | **Decide the repaint mechanism.** Research the two candidates and record the choice in an ADR under `docs/adr/`. Candidate A: on a new attach, the daemon nudges the PTY window size (shrink one row, then restore) so the foreground program repaints via `SIGWINCH`. Candidate B: on a new attach, the daemon replays from the last alternate-screen-enter / full-clear it finds in the ring (a bounded scan, like `OscMarkScanner`, no screen model), so xterm lands on the right buffer with the last coherent frame. Name the cost each imposes on the controller. | The accepted ADR in `docs/adr/`, and the human's merge of it (Propose tier). |
| 2 | **Implement the chosen mechanism on attach.** The daemon applies the repaint path when a client attaches to a session whose foreground program holds the alternate screen. | A daemon test: a fresh attach to a fixture session on the alternate screen yields a coherent frame (the alt-screen-enter is present and the frame is not cut mid-sequence). Completion condition 1. |
| 3 | **Guard the controller and the normal screen.** A second attach does not corrupt the controller, and a normal-screen session still replays its scrollback tail. | A daemon test for completion conditions 2 and 3, and the `KittermBench` TUI-redraw scenario within its noise floor. |

Capability 2 depends on 1 (the ADR decides what 2 builds). Capability 3
depends on 2. None is independent.
