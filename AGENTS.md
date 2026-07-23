# AGENTS.md — kitterm

Guidance for coding agents working in this repo.

## Product shape

- **Browser terminal only** — xterm.js client served by a Swift loopback daemon
- Tab open = new shell; session id in `sessionStorage` keeps "tab = shell"
- Transient disconnects (sleep/wake, reload) **detach** the PTY: output buffers (1MB cap, then reads pause), client auto-reconnects with backoff + on focus/online/visible; unreattached sessions are reaped after 5 min (suspending clock)
- **Sessions are URLs**: `/?cwd=<path>` deep-links a new shell (`kitterm open <path>`); `/?session=<uuid>` joins a session — first client is controller, later ones are read-only observers (128KB replay tail, resize broadcast, share button copies the link); `/?hist=<key>` selects a per-pane history file
- **Split panes** (client): one browser tab holds a binary tree of panes (⌘D / ⌘⇧D split, ⌘⌥↑↓ / click focus, ⌘⌥T new browser tab in the focused pane's cwd). Layout + per-pane `{sessionId, cwd, histKey}` persist in `sessionStorage`; a reload restores the tree and reattaches each pane. Daemon is unchanged — N panes are just N WebSockets
- **Restart resilience**: the daemon polls each shell's cwd via `proc_pidinfo` (~2s, diff-gated) and pushes `cwd` frames, so a restored pane respawns where it was even when the shell emits no OSC 7. Each pane's `?hist=<key>` maps to `~/.kitterm/history/<key>` (set as `HISTFILE`, seeded once from the user's global history), so up-arrow survives a restart with that pane's own commands
- `--lan` binds 0.0.0.0 with token auth for non-loopback peers (`?token=` → cookie; `~/.kitterm/token`); loopback stays trusted
- `--record` writes asciinema v2 casts to `~/.kitterm/recordings/`
- Tab title is per-session (custom name + optional cwd folder), stored per session id; observers adopt the controller's title and cannot edit it
- `kitterm service install` runs the daemon from a per-user LaunchAgent — see **Service** below
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
| S→C | `6` | resize `cols:u16 rows:u16` BE (observer follows controller size) |
| S→C | `7` | role `u8` (0 controller, 1 observer) |

Flow-control defaults: ~2ms / 64KB batching, PTY pause at 4MB buffered outbound, resume at 1MB, hard close at 64MB.

## Security

- Bind `127.0.0.1` by default; `--lan` is the only path that widens it (0.0.0.0 + token auth)
- Enforce Host / Origin against loopback hostnames
- No TLS, no multi-user model — shells run as the invoking user

## State

`~/.kitterm/{pid,port,token,server.log,lastlogin}` plus `recordings/` and
`history/<key>` (per-pane) — default port **3418**.

## Distribution

Releases ship a universal tarball; `scripts/install.sh` unpacks it into a prefix
(default `~/.local`):

```
<prefix>/bin/kitterm              # sh wrapper, execs the real binary
<prefix>/lib/kitterm/kitterm      # argv[0] lands here, so the helper is a sibling
<prefix>/lib/kitterm/kitterm-spawn-helper
<prefix>/share/kitterm/web/       # prebuilt UI (StaticFileServer's installed root)
```

The wrapper exists so `SpawnHelperPath.resolve()` finds the helper beside argv[0].
**This layout is encoded in four places** — `scripts/build-release.sh`,
`scripts/install.sh`, `StaticFileServer.candidateRoots()`, and `SpawnHelperPath` —
so changing it means changing all four, and nothing fails at build time if you don't.

## Service

`kitterm service install|uninstall|status` writes a LaunchAgent
(`~/Library/LaunchAgents/com.kitterm.daemon.plist`, `KeepAlive=true`) pointing at
`<prefix>/bin/kitterm`.

While the agent is loaded **it owns the daemon**: `stop` boots it out before
signalling (a bare SIGTERM would just be undone by KeepAlive), `restart` kickstarts
it, `start` refuses, and reconfiguring means re-running `service install`. Any code
that stops or replaces the daemon must account for the agent — including
`scripts/install.sh`, which boots out before the file swap and re-bootstraps after.

## Coding standards

- Single responsibility per file/type
- KISS: simplest working solution first
- Do not copy large copyrighted chunks from ttyd / localterm
- Keep JSON off the I/O stream (health/API only)
- **No regressions in performance, core features, or UX** — verify with `swift test`
  and `KittermBench` before calling work done; nothing that adds blocking I/O to the
  event loop or per-connection path

## Commands

```bash
swift build
swift test
cd Web/terminal && pnpm install && pnpm build
swift run kitterm start|stop|status|restart
swift run KittermBench                     # against a running daemon
./scripts/build-release.sh v0.1.0          # universal tarball → dist/
```

`KittermBench`'s `TUI-redraw` scenario is flaky — it intermittently reads ~193 B
instead of ~159 KB when it races shell startup. Re-run before treating it as a
regression.
