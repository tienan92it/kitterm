<div align="center">

# kitterm

**Your macOS terminal, in a browser tab.**

Each tab is a shell — lightweight, AI-agent friendly, watchable from any device.

[![Release](https://img.shields.io/github/v/release/tienan92it/kitterm?color=3fb950)](https://github.com/tienan92it/kitterm/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20%7C%20Linux-lightgrey)](https://github.com/tienan92it/kitterm)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

A loopback terminal daemon. It serves [xterm.js](https://xtermjs.org) over a
local HTTP/WebSocket server, so a browser tab becomes a real shell with a controlling
TTY — job control, `Ctrl+C`, TUIs and all. The daemon is Swift + [SwiftNIO](https://github.com/apple/swift-nio),
with no Node on the hot path.

macOS is the primary target. It also runs on Linux, which is how you put an agent in a
container that outlives your laptop — see [Linux](#linux) below.

## Install

```sh
curl -fsSL https://kitterm.dev/install.sh | sh
kitterm start
# → http://kitterm.localhost:3418/
```

> [!NOTE]
> Releases are unsigned. The installer clears the quarantine attribute for you; if you
> extract the tarball by hand, run `xattr -dr com.apple.quarantine <prefix>` first.

### Linux

For containers and cloud boxes. The tarball is statically linked, so the host needs no
Swift toolchain, and it carries its own web bundle — extracting it is the whole install:

```sh
V=v0.15.0; ARCH=amd64        # or arm64
curl -fsSL -o kitterm.tar.gz \
  https://github.com/tienan92it/kitterm/releases/download/$V/kitterm-$V-linux-$ARCH.tar.gz
sudo tar -xzf kitterm.tar.gz -C /usr/local

kitterm integrate bash >> ~/.bashrc   # see below — do not skip this
kitterm start --agent-control
```

Three differences worth knowing:

- **Shell integration is not optional here.** A bare container emits no OSC 133 marks, so
  without the snippet `⌘↑`/`⌘↓` do nothing and `/api/sessions/<id>/commands` stays empty —
  the evidence layer an orchestrator reads is simply dark.
- **There is no launchd**, so `kitterm start` detaches the daemon from your shell rather
  than rooting it in a login session. `kitterm service` still answers, but it manages a
  launchd job, so there is nothing for it to install here — use your init system, or
  `restart: unless-stopped` if this is a container.
- **Reaching it from outside** wants a token and a name it trusts. Behind `tailscale serve`
  or any reverse proxy, keep the daemon on loopback and pass
  `--trusted-host <name>`; those requests are then treated as remote and must present a
  token, so the proxy cannot become an unauthenticated way in.

For a container with this already wired up — plus coding agents, Tailscale and git — see
[agentbox](https://github.com/tienan92it/agentbox).

## Usage

```sh
kitterm start [--port PORT] [--lan] [--record] [--agent-control] [--retain-logs]
              [--rotate-token]
              [--trusted-host NAME] [--tls-cert FILE --tls-key FILE [--tls-port PORT]]
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
| **Browse for context** | ⌘⌥O opens a small browser at your cursor, on the machine the session runs on. Type to filter, arrows move, → opens a folder, ← goes up, ⏎ inserts the real path — no copy, so an agent edits the actual file. ⇧⏎ takes the folder itself |
| **Drop files in for context** | Drag a screenshot, log, CSV or PDF onto a pane — or share one from your phone — and the path where it landed appears at your cursor, ready to hand to a coding agent. Nothing runs until you press Enter |
| **Drive it from a program** | Tag a session (`/ws?label=run:1,node:build`), then `POST /api/sessions/<id>/input` to run a command, `GET …/commands/<n>/wait` to block for its exit code, and `GET …/commands/<n>/output` for the bytes. Labelled sessions outlive the program that made them, so a crashed orchestrator finds its work still running. Command numbers stay put for the life of a session, so an index you saved still means the command you meant. `--retain-logs` keeps output past the 4 MiB in-memory window |
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

**1. Tailscale Serve — simplest, and what I'd pick.** Tailscale terminates TLS with a
publicly trusted certificate and proxies to kitterm on loopback. Nothing to install on
your phone, no certificate files to manage, and renewals are Tailscale's problem:

```sh
kitterm start --trusted-host mac.tailnet.ts.net    # stays on loopback
tailscale serve --bg 3418
# → https://mac.tailnet.ts.net/
```

Enable HTTPS certificates once for your tailnet first, under
[DNS → HTTPS Certificates](https://login.tailscale.com/admin/dns). `--trusted-host` is
what lets kitterm answer to that name; requests naming it still need a token, so the
proxy can't become an unauthenticated way in.

**2. Any other reverse proxy.** Same shape with Caddy or nginx:

```sh
kitterm start --trusted-host kitterm.example.com
```

```nginx
location / {
    proxy_pass http://127.0.0.1:3418;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;      # WebSocket
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 3600s;                    # long-lived sessions
    proxy_buffering off;                         # stream output, don't batch it
}
```

```caddyfile
kitterm.example.com {
    reverse_proxy 127.0.0.1:3418
}
```

**3. kitterm's own TLS**, when you have a certificate but no proxy. The plain listener
stays on loopback and an encrypted one serves everyone else, so plaintext never leaves
the machine. kitterm does not generate certificates:

```sh
kitterm start --tls-cert mac.crt --tls-key mac.key --trusted-host mac.example.com
# Local:  http://kitterm.localhost:3418/   (loopback only)
# Remote: https://mac.example.com:3419/    (TLS)
```

> [!NOTE]
> To use a Tailscale certificate here, fetch it through stdout — the macOS Tailscale CLI
> is sandboxed, so `--cert-file mac.crt` silently writes inside its own container:
> ```sh
> tailscale cert --cert-file - mac.tailnet.ts.net > mac.crt
> tailscale cert --key-file  - mac.tailnet.ts.net > mac.key && chmod 600 mac.key
> ```
> A renewed certificate needs a `kitterm restart` to take effect; Serve (option 1) has
> no such step.

**4. SSH tunnel** — `ssh -L 3418:localhost:3418 your-mac`, then `localhost:3418` on the
other machine. Nothing to configure, but no phone or iPad.

**5. `--lan`, on a network you fully trust** — home Wi-Fi, not a café.

> [!WARNING]
> **`--lan` alone speaks plain HTTP: the access token and every keystroke cross the
> network unencrypted.** Anyone sniffing that network can capture the token and get a
> shell as you. Browsers also withhold the clipboard API from non-HTTPS LAN origins, so
> terminal copy/paste stops working there. Add a certificate (option 1) or a proxy
> (option 2) and both problems go away.

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
tag does the same in CI, for macOS and both Linux architectures.

On Linux, `swift build` works but `swift test` does not: several test files use
`Bundle(for:)`, which corelibs-XCTest has no equivalent for. `KittermBench` is macOS-only
for the same class of reason — it drives the daemon with `URLSessionWebSocketTask`, which
corelibs-foundation does not implement — but it can measure a Linux daemon remotely with
`--port`. Linux tarballs come from `./scripts/build-release-linux.sh`, which links both
binaries statically and refuses to package one that still needs the Swift runtime.

## License

[MIT](LICENSE) · Inspired by [localterm](https://github.com/millionco/localterm)
