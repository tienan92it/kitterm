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
curl -fsSL https://kitterm.dev/install.sh | sh
kitterm start
# → http://kitterm.localhost:3418/
```

> [!NOTE]
> Releases are unsigned. The installer clears the quarantine attribute for you; if you
> extract the tarball by hand, run `xattr -dr com.apple.quarantine <prefix>` first.

## Usage

```sh
kitterm start [--port PORT] [--lan] [--record]
kitterm stop | status | restart
kitterm open [PATH]
kitterm service install | uninstall | status
kitterm upgrade | version
```

State lives in `~/.kitterm/`; the default port is `3418`.

| Feature | How |
| --- | --- |
| **A tab is a shell** | Open a tab to get one; close it and the shell dies |
| **Split panes** | ⌘D / ⌘⇧D split; ⌘⌥T opens a new tab in the same directory |
| **Survives restart** | Reload after `kitterm restart` — each pane returns in its last directory, with its own history |
| **Survives disconnects** | Every session keeps a 4 MiB output log; a reconnect replays exactly the bytes you missed |
| **Command marks** | Any shell emitting OSC 133 (most modern prompts do): ⌘↑/⌘↓ jump between prompts, failed commands get a red dot, `/api/sessions/<id>/marks` lists what ran and how it exited. Shells without it can source [shell-integration.zsh](scripts/shell-integration.zsh) |
| **Open in a directory** | `kitterm open ~/proj`, or link `/?cwd=/path` |
| **Share a session** | ⧉ copies `/?session=<id>` — first client controls, others observe read-only |
| **Phone / LAN access** | `kitterm start --lan` prints a token-gated URL |
| **Record sessions** | `kitterm start --record` → asciinema casts in `~/.kitterm/recordings/` |
| **Start on login** | `kitterm service install` |
| **Self-update** | `kitterm upgrade` installs the latest release |

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
