<div align="center">

# kitterm

**Your macOS terminal, in a browser tab.**

Each tab is a shell — lightweight, AI-agent friendly, watchable from any device.

[![Release](https://img.shields.io/github/v/release/tienan92it/kitterm?color=3fb950)](https://github.com/tienan92it/kitterm/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](https://github.com/tienan92it/kitterm)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

A loopback terminal daemon for macOS. It serves [xterm.js](https://xtermjs.org) over a
local HTTP/WebSocket server, so a browser tab becomes a real shell with a controlling
TTY — job control, `Ctrl+C`, TUIs and all. The daemon is Swift + [SwiftNIO](https://github.com/apple/swift-nio),
with no Node on the hot path.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/tienan92it/kitterm/main/scripts/install.sh | sh
kitterm start
# → http://kitterm.localhost:3418/
```

Installs a universal binary and prebuilt UI into `~/.local` — no Swift or Node
required. Override with `KITTERM_PREFIX=/usr/local`.

> [!NOTE]
> Releases are unsigned. The installer clears the quarantine attribute for you; if you
> extract the tarball by hand, run `xattr -dr com.apple.quarantine <prefix>` first.

## Usage

```sh
kitterm start [--port PORT] [--lan] [--record]
kitterm stop | status | restart
kitterm open [PATH]                  # new browser shell in PATH
kitterm service install | uninstall  # start on login via LaunchAgent
```

Open a tab to get a shell; close it and the shell dies. Sleep, reload, or a dropped
network detaches the PTY and buffers output — the client reconnects and picks up where
it left off. State lives in `~/.kitterm/`; the default port is `3418`.

**Sessions are URLs.** `/?cwd=/path` opens a shell in that directory (what `kitterm open`
links to), and `/?session=<id>` joins an existing one — the first client controls it,
everyone after observes read-only. The ⧉ button copies the link.

**`--lan`** binds all interfaces and prints a token-gated URL for your phone or tablet
(token also in `~/.kitterm/token`). **`--record`** writes [asciinema](https://asciinema.org)
v2 casts to `~/.kitterm/recordings/`.

## Security

kitterm binds `127.0.0.1` and validates `Host`/`Origin` against loopback names, so a
malicious page can't reach the daemon from your browser. `--lan` widens this
deliberately and adds token auth for non-loopback peers.

> [!WARNING]
> There is no TLS and no multi-user model — kitterm serves shells as the user running
> it, and anyone with a `--lan` link gets one. Don't expose it to an untrusted network.

## Building from source

Requires Swift 6 and Node 22+ with pnpm.

```sh
swift build
(cd Web/terminal && pnpm install && pnpm build)
swift run kitterm start
```

`swift test` runs the suite; `pnpm dev` serves the UI with hot reload against a running
daemon. `./scripts/build-release.sh v0.1.0` produces a release tarball — pushing a `v*`
tag does the same in CI.

## License

[MIT](LICENSE) · Inspired by [localterm](https://github.com/millionco/localterm)
