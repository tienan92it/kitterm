# kitterm

Browser terminal for macOS. Loopback Swift daemon + xterm.js — each tab is one shell.

Inspired by [localterm](https://github.com/millionco/localterm); kitterm keeps the same “tab = shell” model with a Swift/NIO daemon instead of Node on the hot path.

## Quick start

```bash
swift build
cd Web/terminal && pnpm install && pnpm build && cd ../..

swift run kitterm start
# → http://kitterm.localhost:3418/
```

| Tab | Effect |
|-----|--------|
| Open | New shell |
| Sleep / brief disconnect / reload | Auto-reconnects to the same shell |
| Close (or no reattach in 5 min) | Shell dies |

```bash
kitterm status | stop | restart
kitterm start --port 3420
```

State: `~/.kitterm/` · default port `3418`.

**Dev UI:** `swift run kitterm start` then `cd Web/terminal && pnpm dev` (proxies to the daemon).

**Auto-start:** optional LaunchAgent — see [`launchd/README.md`](launchd/README.md).

## Requirements

macOS 13+ · Swift 6 · Node 20+ / pnpm

## Notes

- Local-only: binds `127.0.0.1`, loopback Host/Origin checks. Do not expose publicly without auth/TLS.
- `swift build` emits `kitterm` and `kitterm-spawn-helper` side by side (required for Ctrl+C / SIGINT).
- Settings (gear / ⌘,): themes, fonts (system fonts via Local Font Access in Chrome/Edge), size — `localStorage`.

## License

MIT
