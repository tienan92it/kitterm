<div align="center">

# kitterm

**Your macOS terminal, in a browser tab.**

Each tab is a shell — lightweight, AI-agent friendly, watchable from any device.

[![Release](https://img.shields.io/github/v/release/tienan92it/kitterm?color=3fb950)](https://github.com/tienan92it/kitterm/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](https://github.com/tienan92it/kitterm)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

kitterm is a loopback terminal daemon for macOS. It serves [xterm.js](https://xtermjs.org)
over a local HTTP/WebSocket server, so any browser tab becomes a real shell with a
controlling TTY — job control, `Ctrl+C`, TUIs and all.

The daemon is Swift + [SwiftNIO](https://github.com/apple/swift-nio) with no Node on
the hot path, so PTY output goes straight from the kernel to the socket.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/tienan92it/kitterm/main/scripts/install.sh | sh
kitterm start
# → http://kitterm.localhost:3418/
```

Installs a universal binary and a prebuilt UI into `~/.local` — no Swift or Node
required. Override the location with `KITTERM_PREFIX=/usr/local`.

> [!NOTE]
> Releases are unsigned. The installer clears the quarantine attribute for you; if
> you extract the tarball by hand, run `xattr -dr com.apple.quarantine <prefix>` first.

## Why

- **A tab is a shell.** Open a tab, get a shell. Close it, the shell dies.
- **Survives disconnects.** Sleep, reload, or a dropped network detaches the PTY and
  buffers output; the client reconnects with backoff and picks up where it left off.
- **Sessions are URLs.** Deep-link a working directory, or share a live session for
  someone to watch read-only.
- **Watchable from anywhere.** `--lan` exposes a token-gated URL for your phone or
  tablet — useful for keeping an eye on a long-running agent or build.
- **Recordable.** `--record` writes asciinema-compatible casts of every session.

## Usage

```sh
kitterm start [--port PORT] [--lan] [--record]   # start the daemon
kitterm stop | status | restart                  # lifecycle
kitterm open [PATH]                              # new browser shell in PATH
```

State lives in `~/.kitterm/` (`pid`, `port`, `token`, `server.log`); the default port
is `3418`.

### Sessions are URLs

| URL | Behavior |
| --- | --- |
| `/` | New shell in your home directory |
| `/?cwd=/path` | New shell in that directory — what `kitterm open` links to |
| `/?session=<id>` | Join an existing session |

The first client to join a session controls it; everyone after is a read-only
**observer** that follows the controller's output and terminal size. The ⧉ button
copies the session link.

### LAN access

```sh
kitterm start --lan
# LAN access: http://192.168.1.42:3418/?token=…
```

Binds all interfaces and prints a token-gated URL (also stored in `~/.kitterm/token`).
Loopback stays trusted; every other client needs the token.

> [!WARNING]
> Anyone with that link gets a shell as your user. Share it deliberately, and prefer
> a trusted network — kitterm has no TLS.

### Recording

```sh
kitterm start --record
asciinema play ~/.kitterm/recordings/<session>.cast
```

Writes [asciinema](https://asciinema.org) v2 casts, one per session.

### Start on login

```sh
kitterm service install [--port PORT] [--lan] [--record]
kitterm service status
kitterm service uninstall
```

Installs a per-user LaunchAgent that runs the daemon from login and restarts it if it
crashes. While the service is active it owns the daemon: `kitterm restart` restarts
the agent, and reconfiguring means re-running `service install` with new flags.

## Configuration

Themes, fonts, and font size live behind the gear icon (or `⌘,`) and persist in
`localStorage`. In Chrome and Edge, kitterm can enumerate your installed system fonts
via the Local Font Access API.

## Security

kitterm binds `127.0.0.1` by default and validates the `Host` and `Origin` headers
against loopback names, so a malicious page can't reach the daemon from your browser.
`--lan` widens this deliberately and adds token authentication for non-loopback peers.

There is no TLS and no multi-user model: kitterm serves shells as the user running it.
Do not expose it to an untrusted network.

## Building from source

Requires Swift 6 and Node 22+ with pnpm.

```sh
git clone https://github.com/tienan92it/kitterm.git
cd kitterm
swift build
(cd Web/terminal && pnpm install && pnpm build)
swift run kitterm start
```

For UI work, run the daemon and Vite side by side — `pnpm dev` proxies to the daemon:

```sh
swift run kitterm start
(cd Web/terminal && pnpm dev)
```

Run the test suite with `swift test`, and the throughput/latency benchmarks against a
running daemon with `swift run KittermBench`.

### Releases

```sh
./scripts/build-release.sh v0.1.0   # → dist/kitterm-v0.1.0-macos-universal.tar.gz
```

Builds both architectures, merges them with `lipo`, and bundles the prebuilt UI.
Pushing a `v*` tag runs the same script in CI and publishes the tarball.

## Architecture

| Component | Role |
| --- | --- |
| `KittermCLI` | `kitterm` command — daemon lifecycle and LaunchAgent management |
| `KittermDaemon` | NIO HTTP/WebSocket server, PTY sessions, static assets, recording |
| `KittermProtocol` | Binary frame format shared by daemon and client |
| `KittermSpawnHelper` | Small helper that gives each shell a controlling TTY |
| `Web/terminal` | xterm.js client (TypeScript + Vite) |

Client and daemon speak a compact binary protocol over one WebSocket — a single
leading byte tags each frame (input, resize, output, title, cwd, exit code, session
id, role), keeping JSON off the I/O path.

## Acknowledgements

Inspired by [localterm](https://github.com/millionco/localterm). kitterm keeps the
"tab = shell" model and replaces the Node hot path with a Swift/NIO daemon.

## License

[MIT](LICENSE)
