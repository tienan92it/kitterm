# kitterm

Mac-first dual-surface terminal: native SwiftUI + SwiftTerm Metal tabs as the primary UX, with a loopback Swift daemon using a ttyd-style binary WebSocket protocol. An optional browser xterm.js client shares the same protocol.

## Status

Phase 0–5: protocol, daemon/CLI, native SwiftUI + SwiftTerm Metal app, browser client, Mac integration (launchd + App Intents stub), and `KittermBench` regression harness.

## Requirements

- macOS 13+
- Swift 6 / Xcode toolchain
- Node 20+ / pnpm (browser client)

## Build

```bash
swift build
swift test
```

Browser client:

```bash
cd Web/terminal
pnpm install
pnpm build
```

Release binaries:

```bash
swift build -c release
# .build/release/kitterm     — daemon CLI
# .build/release/KittermApp  — native Mac app
```

## Native app

Start the daemon, then launch the app:

```bash
swift run kitterm start
swift run KittermApp
```

Or open the built binary:

```bash
.build/debug/KittermApp
```

- Tabs map 1:1 to daemon WebSocket sessions (new tab → new shell; close → kill PTY)
- Tab / window chrome: OSC title when set, else cwd basename, else shell name (tooltip shows full cwd)
- Settings (⌘,): font, size, theme, cursor, scrollback (UserDefaults)
- New Tab ⌘T / Close Tab ⌘W
- Copy / Paste / Select All (⌘C / ⌘V / ⌘A) via the Edit menu

Browser client extras: ⌘/Ctrl+F search, selection copy, ⌘/Ctrl+Shift+V paste, WebGL renderer.

## Bench

With the daemon running:

```bash
swift run KittermBench              # all scenarios
swift run KittermBench interactive-echo
swift run KittermBench TUI-redraw
swift run KittermBench large-burst
```

See [`Bench/README.md`](Bench/README.md) for metrics and how to interpret results.

## CLI

State lives in `~/.kitterm/` (`pid`, `port`, `server.log`).

```bash
kitterm start          # bind 127.0.0.1:3418 (default)
kitterm start --port 3420
kitterm status
kitterm restart
kitterm stop
```

After `pnpm build`, the daemon serves `Web/terminal/dist`. `kitterm start` opens `http://kitterm.localhost:<port>/` when those assets are present.

Health check (off the I/O hot path):

```bash
curl -s http://127.0.0.1:3418/api/health
# {"ok":true,"sessions":0}
```

WebSocket sessions: `ws://127.0.0.1:<port>/ws`  
Binary frames — see `AGENTS.md` / `Sources/KittermProtocol`.

### Dev (Vite proxy)

With the daemon running on 3418:

```bash
cd Web/terminal && pnpm dev
# http://localhost:5173 — proxies /ws and /api to the daemon
```

## launchd (optional auto-start)

A user LaunchAgent plist lives in [`launchd/`](launchd/). It runs `kitterm serve` in the foreground so launchd owns the process (not `kitterm start`, which detaches).

```bash
swift build -c release
cp .build/release/kitterm /usr/local/bin/kitterm   # or edit the plist path

mkdir -p ~/Library/LaunchAgents
cp launchd/com.kitterm.daemon.plist ~/Library/LaunchAgents/
# Edit ProgramArguments[0] if the binary is not at /usr/local/bin/kitterm

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.kitterm.daemon.plist
launchctl enable gui/$(id -u)/com.kitterm.daemon
kitterm status
```

Uninstall:

```bash
launchctl bootout gui/$(id -u)/com.kitterm.daemon
rm -f ~/Library/LaunchAgents/com.kitterm.daemon.plist
```

Details: [`launchd/README.md`](launchd/README.md).

## App Intents

`Apps/Kitterm/NewKittermTabIntent.swift` defines a **New Kitterm Tab** intent (and App Shortcut phrases). It posts an in-process notification that opens a tab — same as ⌘T.

**SPM limit:** `swift run KittermApp` / `.build/*/KittermApp` is a bare executable. Shortcuts, Siri, and App Intents metadata extraction require an `.app` bundle. Until KittermApp is packaged that way, the intent compiles but will not appear in Shortcuts.

### Xcode packaging path (when you want Shortcuts)

1. Create a macOS App project (or XcodeGen) that builds an `.app` with bundle id e.g. `com.kitterm.app`.
2. Add the `Apps/Kitterm` sources (or depend on the SPM `KittermApp` target sources) to that app target — not only as a tool executable.
3. Ensure the target links `AppIntents` and runs the standard App Intents metadata extract build phase (Xcode app targets do this by default).
4. Install/run the `.app` once so the system indexes intents; then **New Kitterm Tab** should appear in Shortcuts.

## Security model

kitterm is built for a **local-personal** threat model: the daemon is a PTY broker on your machine, not a remote terminal server.

| Control | Behavior |
| -------- | -------- |
| Bind address | `127.0.0.1` only (`KittermConstants.defaultHost`). No dual-stack / interface bind in MVP. |
| Host header | HTTP/WS rejected unless Host is a known loopback name (`127.0.0.1`, `localhost`, `kitterm.localhost`, `::1`, …). |
| Origin header | If present, must be a loopback origin; non-local Origins are rejected. |
| Transport | Cleartext on loopback. No TLS, no auth proxy, no remote bind in MVP. |
| State | `~/.kitterm/` is per-user (pid, port, log). |

What this means:

- Another process on your Mac that can open loopback sockets can talk to the daemon (same class of risk as many local-dev tools).
- LAN / WAN clients cannot reach the daemon unless something else tunnels to loopback.
- Do not reverse-proxy kitterm to the public internet without adding auth and TLS yourself (out of scope).

Enforcement lives in `Sources/KittermDaemon/LoopbackSecurity.swift`.

## Layout

```
Package.swift
Sources/KittermProtocol/   # frame codecs + constants
Sources/KittermDaemon/     # HTTP+WS, PTY, sessions
Sources/KittermCLI/        # kitterm start|stop|status|restart
Sources/KittermBench/      # binary-protocol regression harness
Apps/Kitterm/              # SwiftUI + SwiftTerm Metal app
Web/terminal/              # browser client (xterm WebGL + search)
launchd/                   # optional user LaunchAgent
Bench/scenarios/           # scenario notes + pass criteria
```

## License

MIT
