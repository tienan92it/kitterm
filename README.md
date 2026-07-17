# kitterm

Your terminal in a browser tab.

Run the daemon, open `http://kitterm.localhost:3418/` — each tab is one shell. Close the tab to kill it. Reload starts a fresh shell.

## Quick start

```bash
# once
swift build
cd Web/terminal && pnpm install && pnpm build && cd ../..

# every time
swift run kitterm start
# → opens http://kitterm.localhost:3418/
```

| Action | Effect |
|--------|--------|
| Open URL / new browser tab | New shell |
| Close tab | Shell dies |
| Reload | Fresh shell |

```bash
kitterm status
kitterm stop
kitterm restart
kitterm start --port 3420   # if 3418 is busy
```

State: `~/.kitterm/` (`pid`, `port`, `server.log`).

### Dev (hot reload UI)

```bash
swift run kitterm start
cd Web/terminal && pnpm dev
# http://localhost:5173 — proxies /ws and /api to the daemon
```

## Requirements

- macOS 13+
- Swift 6 toolchain
- Node 20+ / pnpm (web UI)

## Browser features

- xterm.js + WebGL
- Settings (gear / ⌘,): themes, fonts (including system fonts via Local Font Access in Chrome/Edge), font size — stored in `localStorage` (`kitterm:*`)
- ⌘F / Ctrl+Shift+F search; ⌘C / Ctrl+Shift+C copy; ⌘V / Ctrl+Shift+V paste (Ctrl+C = interrupt)
- Kitty keyboard helpers for modern TUIs
- Document title: OSC title → cwd basename → shell name

## Optional: auto-start daemon

See [`launchd/README.md`](launchd/README.md) to install a LaunchAgent that runs `kitterm serve`.

## Bench

```bash
swift run kitterm start
swift run KittermBench
```

See [`Bench/README.md`](Bench/README.md).

## Security

Local-only: binds `127.0.0.1`, rejects non-loopback Host/Origin. No TLS / remote bind.

| Control | Behavior |
|---------|----------|
| Bind | `127.0.0.1` only |
| Host / Origin | Loopback names only (`127.0.0.1`, `localhost`, `kitterm.localhost`, …) |
| State | Per-user `~/.kitterm/` |

Do not expose kitterm on the public internet without adding auth/TLS yourself.

## Layout

```
Sources/KittermProtocol/      # binary WS frames
Sources/KittermDaemon/        # HTTP + WS + PTY
Sources/KittermCLI/           # kitterm start|stop|status|restart
Sources/KittermSpawnHelper/   # acquires controlling TTY (Ctrl+C / SIGINT)
Sources/KittermBench/         # regression harness
Web/terminal/                 # browser client
launchd/                      # optional LaunchAgent
```

`swift build` produces both `kitterm` and `kitterm-spawn-helper` (must sit next to each other).

## License

MIT
