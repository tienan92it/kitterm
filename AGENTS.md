# AGENTS.md — kitterm

Guidance for coding agents working in this repo.

## Product shape

- **Native primary:** SwiftUI + SwiftTerm Metal tabs (phase 2+)
- **Daemon:** Swift loopback HTTP + binary WebSocket; tab open = new shell; tab close = kill PTY
- **Browser secondary:** xterm.js on the same protocol (phase 4)
- **No Node on the hot path**

## Binary protocol (`KittermProtocol`)

| Dir | Byte | Payload |
|-----|------|---------|
| C→S | `0` | UTF-8 / raw input |
| C→S | `1` | `cols:u16` `rows:u16` (big-endian) |
| C→S | `2` / `3` | pause / resume (empty) |
| S→C | `0` | raw PTY output |
| S→C | `1` | title UTF-8 |
| S→C | `2` | session meta (length-prefixed fields) |
| S→C | `3` | cwd UTF-8 |
| S→C | `4` | exit code `i32` BE |

Flow-control defaults (inspired by localterm numbers, reimplemented): ~2ms / 64KB batching, PTY pause at 4MB buffered outbound, resume at 1MB, hard close at 64MB. Immediate flush on quiet interactive echo.

## Security

- Bind `127.0.0.1` only
- Enforce Host / Origin against loopback hostnames
- Reject non-loopback; no TLS / remote bind in MVP

## State

`~/.kitterm/{pid,port,server.log}` — CLI start/stop/status/restart.

Default port: **3418** (avoids localterm’s 3417).

## Coding standards

- Single responsibility per file/type
- KISS: simplest working solution first
- Do not copy large copyrighted chunks from ttyd / localterm
- Keep JSON off the I/O stream (health/API only)

## Commands

```bash
swift build
swift test
swift run kitterm start|stop|status|restart
swift run KittermBench              # needs daemon; see Bench/README.md
```

## Mac integration (phase 3)

- Optional LaunchAgent: `launchd/com.kitterm.daemon.plist` → `kitterm serve` (foreground). See `launchd/README.md`.
- App Intents stub: `NewKittermTabIntent` in `Apps/Kitterm`. Shortcuts need an Xcode-packaged `.app` (SPM executable has no intents metadata).
- Security: loopback-only; document in README — do not add remote bind/TLS in MVP.

## Phases

0 Bootstrap · 1 Daemon core · 2 Native app · 3 launchd/App Intents · 4 Web client · 5 Perf polish
