# Scenario: large-burst

## Goal

Validate output batching and backpressure under megabyte floods.

## Method

1. **Fast drain:** `dd` ~8MB of zeros; client receives as fast as possible
2. **Slow drain:** `dd` ~2MB with 5ms between WS receives so the TCP/WS write buffer backs up and PTY pause/resume engages
3. Confirm session survives; hard-close (4429) only if outbound truly runs away

## Run

```bash
swift run KittermBench large-burst
```

## Pass criteria

- Fast path delivers the full burst; max frame stays ≤256KiB
- Slow path completes without session drop
- No claim vs localterm without a paired baseline
