# Scenario: TUI-redraw

## Goal

Stress full-screen redraw throughput through the daemon (native Metal frame time is a separate Instruments pass).

## Method

1. Open a session; resize to 80×40
2. Run a synthetic Python ANSI clear+paint loop (~120 frames)
3. Measure bytes received, elapsed time, MB/s, max WS output frame size

## Run

```bash
swift run KittermBench TUI-redraw
```

## Pass criteria

- Sustained redraw without early session/shell drop
- Useful as a before/after daemon regression check
