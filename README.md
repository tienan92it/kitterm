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
kitterm integrate [zsh|bash]
kitterm token create <name> [--watch] | list | revoke <name>
```

State lives in `~/.kitterm/`; the default port is `3418`.

| Feature | How |
| --- | --- |
| **A tab is a shell** | Open a tab to get one; close it and the shell dies |
| **Split panes** | ⌘D / ⌘⇧D split; ⌘⌥T opens a new tab in the same directory |
| **Survives restart** | Reload after `kitterm restart` — each pane returns in its last directory, with its own history |
| **Survives disconnects** | Every session keeps a 4 MiB output log; a reconnect replays exactly the bytes you missed |
| **Command marks** | Any shell emitting OSC 133 (most modern prompts do): ⌘↑/⌘↓ jump between prompts, failed commands get a red dot, `/api/sessions/<id>/marks` lists what ran and how it exited. Shells without it: `kitterm integrate >> ~/.zshrc` locally, or `kitterm integrate bash \| ssh vm 'cat >> ~/.bashrc'` for a remote box — marks travel in-band, so they work through ssh/docker too |
| **Open in a directory** | `kitterm open ~/proj`, or link `/?cwd=/path` |
| **Session profiles** | Name connect commands in `~/.kitterm/profiles.json` — `{"profiles":[{"name":"vm","command":"ssh dev-vm"}]}` — then open `/?profile=vm` or one-click from `/sessions`. The command runs at session start, so a tab *is* that VM/container; splits and restarts re-run it |
| **Share a session** | ⧉ copies `/?session=<id>` — first client controls, others observe read-only. A "Take control" tap hands the session over live: pick up on your phone exactly where the laptop left off |
| **Watch-only links** | 👁 copies a link whose token can *only* observe — never type, take control, or open shells. The daemon enforces it. Durable tokens: `kitterm token create review --watch` (hashed, revocable without restart) |
| **Phone / LAN access** | `kitterm start --lan` prints a token-gated URL |
| **Record sessions** | `kitterm start --record` → asciinema casts in `~/.kitterm/recordings/` |
| **Start on login** | `kitterm service install` |
| **Self-update** | `kitterm upgrade` installs the latest release |

## Security

**By default kitterm binds `127.0.0.1`** and validates `Host`/`Origin` against loopback
names, so a malicious page can't reach the daemon from your browser (the standard
DNS-rebinding defense). `http://kitterm.localhost:3418` is a browser *secure context*,
so clipboard and share links work without TLS. There is no multi-user model: kitterm
serves shells as the user running it, and anyone who can reach it has one.

**Tokens.** `--lan` mints a control token and a watch token per run; `kitterm token
create <name> [--watch]` makes durable ones — stored as SHA-256 hashes, shown once,
revocable while the daemon runs. A **watch** token is enforced daemon-side: it can
observe sessions and read the API, but can never type, take control, or open a shell.

**Reaching kitterm from another device**, best first:

1. **SSH tunnel** — `ssh -L 3418:localhost:3418 your-mac`, then use `localhost:3418`
   on the other machine. Encrypted, no token in a URL, nothing new to install. No good
   on a phone or iPad.
2. **Private overlay network** (Tailscale, WireGuard, ZeroTier) — put both devices on
   it and use `kitterm start --lan` bound to that interface's address. The overlay
   provides the encryption; kitterm's token provides the authorization.
3. **`--lan` on a network you fully trust** — home Wi-Fi, not a café.

> [!WARNING]
> **`--lan` speaks plain HTTP: the access token and every keystroke cross the network
> unencrypted**, so anyone sniffing that network can capture the token and get a shell
> as you. Browsers additionally withhold the clipboard API from non-HTTPS LAN origins,
> which disables terminal copy/paste there. Native TLS and reverse-proxy support are
> planned; until then treat `--lan` as trusted-network-only and prefer 1 or 2 above.

Never put kitterm on a public IP — a public URL in front of a shell is one leaked
token away from remote code execution.

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
