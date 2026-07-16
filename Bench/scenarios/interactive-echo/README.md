# Scenario: interactive-echo

## Goal

Measure input→output round-trip for single-character echoes (typing feel at the daemon boundary).

## Method

1. Open `ws://127.0.0.1:<port>/ws`
2. Resize, drain shell startup noise
3. `exec cat` so each byte echoes once
4. For N keystrokes: send C→S input `0` + byte; wait for that byte in S→C output
5. Record p50 / p95 / p99 latency

## Run

```bash
swift run KittermBench interactive-echo
```

## Pass criteria

- p95 &lt; 50ms on an idle machine (soft gate)
- Quiet interactive path should not sit on the 2ms batch timer
