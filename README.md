# kitterm

Browser terminal for macOS. Loopback Swift daemon + xterm.js — each tab is one shell.

Inspired by [localterm](https://github.com/millionco/localterm); kitterm keeps the same “tab = shell” model with a Swift/NIO daemon instead of Node on the hot path.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/tienan92it/kitterm/main/scripts/install.sh | sh
```

Installs to `~/.local` (override with `KITTERM_PREFIX`). No Swift or Node needed —
the release ships a universal binary and a prebuilt UI.

```bash
kitterm start
# → http://kitterm.localhost:3418/
```

Builds are unsigned. The installer clears the quarantine attribute for you; if you
extract the tarball by hand, run `xattr -dr com.apple.quarantine <prefix>` first.

To uninstall: `kitterm service uninstall` (if enabled), then remove
`~/.local/bin/kitterm`, `~/.local/lib/kitterm`, `~/.local/share/kitterm`, and `~/.kitterm`.

| Tab | Effect |
|-----|--------|
| Open | New shell |
| Sleep / brief disconnect / reload | Auto-reconnects to the same shell |
| Close (or no reattach in 5 min) | Shell dies |

```bash
kitterm status | stop | restart
kitterm start --port 3420
kitterm open ~/proj        # browser shell in that directory
kitterm start --lan        # phone/LAN access (token-gated)
kitterm start --record     # asciinema .cast per session
```

State: `~/.kitterm/` · default port `3418`.

## Sessions are URLs

- `/?cwd=/path` — new shell in that directory (what `kitterm open` uses)
- `/?session=<id>` — join a session: first client controls, others observe read-only (⧉ button copies the link)
- `--lan` prints `http://<lan-ip>:3418/?token=…` — open it on your phone; anyone with the link gets a shell as your user, share carefully

## Auto-start

```bash
kitterm service install     # LaunchAgent, starts on login
kitterm service status
kitterm service uninstall
```

## Building from source

```bash
swift build
cd Web/terminal && pnpm install && pnpm build && cd ../..
swift run kitterm start
```

**Dev UI:** `swift run kitterm start` then `cd Web/terminal && pnpm dev` (proxies to the daemon).

**Release tarball:** `./scripts/build-release.sh v0.1.0` → `dist/` (universal binary +
prebuilt UI). Pushing a `v*` tag runs the same script in CI and publishes the release.

## Requirements

Running: macOS 13+ · Building: Swift 6 · Node 22+ / pnpm 10

## Notes

- Local-only: binds `127.0.0.1`, loopback Host/Origin checks. Do not expose publicly without auth/TLS.
- `swift build` emits `kitterm` and `kitterm-spawn-helper` side by side (required for Ctrl+C / SIGINT).
- Settings (gear / ⌘,): themes, fonts (system fonts via Local Font Access in Chrome/Edge), size — `localStorage`.

## License

MIT
