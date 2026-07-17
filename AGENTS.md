# AGENTS.md — kitterm

Guidance for coding agents working in this repo.

## Product shape

- **Browser terminal only** — xterm.js client served by a Swift loopback daemon
- Tab open = new shell; session id in `sessionStorage` keeps "tab = shell"
- Transient disconnects (sleep/wake, reload) **detach** the PTY: output buffers (1MB cap, then reads pause), client auto-reconnects with backoff + on focus/online/visible; unreattached sessions are reaped after 5 min (suspending clock)
- **No Node on the hot path** (daemon is Swift + NIO)
- No native Mac app
- PTY spawn uses `kitterm-spawn-helper` (must be beside `kitterm`) so the shell gets a controlling TTY — required for Ctrl+C → SIGINT

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
| S→C | `5` | session id UTF-8 (reattach via `/ws?session=<uuid>`) |

Flow-control defaults: ~2ms / 64KB batching, PTY pause at 4MB buffered outbound, resume at 1MB, hard close at 64MB.

## Security

- Bind `127.0.0.1` only
- Enforce Host / Origin against loopback hostnames
- No TLS / remote bind in MVP

## State

`~/.kitterm/{pid,port,server.log}` — default port **3418**.

## Coding standards

- Single responsibility per file/type
- KISS: simplest working solution first
- Do not copy large copyrighted chunks from ttyd / localterm
- Keep JSON off the I/O stream (health/API only)

## Commands

```bash
swift build
swift test
cd Web/terminal && pnpm install && pnpm build
swift run kitterm start|stop|status|restart
swift run KittermBench
```
