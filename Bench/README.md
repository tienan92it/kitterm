# Bench harness

Runnable regression scenarios against a live `kittermd` binary WebSocket (`KittermProtocol`).
Measures daemon I/O behavior (batching, interactive flush, backpressure survival) — not Metal glyph latency (use Instruments for that).

## Prerequisites

```bash
swift build
swift run kitterm start          # default 127.0.0.1:3418
# optional dedicated port:
# swift run kitterm start --port 3420
```

Health check:

```bash
curl -s http://127.0.0.1:3418/api/health
```

## Run

```bash
swift run KittermBench                         # all scenarios
swift run KittermBench interactive-echo
swift run KittermBench TUI-redraw
swift run KittermBench large-burst
swift run KittermBench --port 3420 all
```

Exit code `0` = all gated checks passed; `1` = failure or daemon unreachable.

## Scenarios

| Scenario | Path | What it measures |
|----------|------|------------------|
| Interactive echo | `scenarios/interactive-echo/` | Keystroke → echo RTT via `exec cat` (p50/p95/p99) |
| TUI redraw | `scenarios/TUI-redraw/` | Synthetic full-screen ANSI redraw throughput |
| Large burst | `scenarios/large-burst/` | ~8MB flood drain + slow-drain pause/resume survival |

### Interpreting results

**interactive-echo**

- Reports latency summary in milliseconds.
- Soft gate: `p95 < 50ms` on a quiet machine. Higher values usually mean shell noise, CPU contention, or the batcher delaying quiet echoes (should be rare — quiet path flushes immediately).
- This is daemon+PTY RTT, not native Metal input→glyph latency.

**TUI-redraw**

- Reports bytes transferred, elapsed time, and MB/s.
- Soft gate: sustained redraw without an early shell/session drop.
- Useful for comparing machines / before-after daemon changes; not a localterm bake-off unless you run both under the same harness.

**large-burst**

- Fast drain: expects ≥8MB received; `maxFrame` should stay ≤256KiB (batcher targets 64KB/2ms).
- Slow drain: 5ms between WS receives while pumping ~2MB — session must survive (PTY pause/resume). Hard-close (4429) or early exit = fail.
- Does not claim “beats localterm” without a paired baseline run.

## Notes

- Harness uses `URLSessionWebSocketTask` with loopback `Host`/`Origin`.
- Scenarios drive a login shell over the protocol; they send shell commands (`exec cat`, `python3`, `dd`).
- Keep Instruments / Metal frame timing as a separate native-only pass when optimizing the app renderer.
