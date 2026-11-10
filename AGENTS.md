# AGENTS.md — kitterm

Guidance for coding agents working in this repo.

## Where the specification lives

The product specification is under `docs/`, one file per surface. Read the file
for the surface you change, and update it in the same round: a round that
changes a surface updates that surface's file.

- `docs/product-shape.md` — what kitterm is: the browser terminal, sessions as
  URLs, the fleet view, the Markdown preview, the `/edit` page, split panes,
  restart resilience, tokens, labels, the foreman, the daemon's one exception
  to "no terminal emulation"
- `docs/binary-protocol.md` — the WebSocket opcodes of `KittermProtocol`, both
  directions, and the flow-control defaults
- `docs/http-api.md` — every HTTP route, its shape, its grade, and the rules
  behind it
- `docs/security.md` — the bind, token, host and proxy rules, and what each
  route exposes
- `docs/control-plane.md` — the `docs/goals/` package, the goal and chore
  commands, `design/`, and the foreman's files
- `docs/architecture.md` — the shape of the daemon and the client, and the
  state on disk
- `docs/live-upgrade.md` — the exec takeover
- `docs/foreman.md` — the operating manual of the foreman
- `docs/adr/` — one record per decision the code does not explain

## State

Everything lives under `~/.kitterm/`, default port **3418**. The tree, in the
order `DaemonPaths.swift` declares it, is in `docs/architecture.md` under
"State on disk"; edit it there when `DaemonPaths.swift` changes.

## Distribution

Releases ship a universal macOS tarball and statically linked Linux tarballs
(`amd64`, `arm64`); `scripts/install.sh` unpacks the macOS one into a prefix
(default `~/.local`). The Linux ones use the same layout and are meant to be
extracted straight into `/usr/local`:

```
<prefix>/bin/kitterm              # sh wrapper, execs the real binary
<prefix>/lib/kitterm/kitterm      # argv[0] lands here, so the helper is a sibling
<prefix>/lib/kitterm/kitterm-spawn-helper
<prefix>/share/kitterm/web/       # prebuilt UI (StaticFileServer's installed root)
```

The wrapper exists so `SpawnHelperPath.resolve()` finds the helper beside argv[0].
**This layout is encoded in five places** — `scripts/build-release.sh`,
`scripts/build-release-linux.sh`, `scripts/install.sh`,
`StaticFileServer.candidateRoots()`, and `SpawnHelperPath` — so changing it means
changing all five, and nothing fails at build time if you don't.

Linux binaries must be linked with `--static-swift-stdlib`, **including the C spawn
helper**: SwiftPM links it against `libswiftCore` regardless, and a helper that needs
the Swift runtime execs fine and then kills every session on a host without a
toolchain. `build-release-linux.sh` refuses to package a build that still links it.

## Service

`kitterm service install|uninstall|status` writes a LaunchAgent
(`~/Library/LaunchAgents/com.kitterm.daemon.plist`, `KeepAlive=true`) pointing at
`<prefix>/bin/kitterm`.

While the agent is loaded **it owns the daemon**: `stop` boots it out before
signalling (a bare SIGTERM would just be undone by KeepAlive), `restart` kickstarts
it, `start` refuses, and reconfiguring means re-running `service install`. Any code
that stops or replaces the daemon must account for the agent — including
`scripts/install.sh`, which boots out before the file swap and re-bootstraps after.
`upgrade --live` needs the agent for the opposite reason: the daemon execs the new
build under the same job, and KeepAlive is what restarts it clean if that build
crashes after the exec.

## Coding standards

- Single responsibility per file/type
- KISS: simplest working solution first
- Do not copy large copyrighted chunks from ttyd / localterm
- Keep JSON off the I/O stream (health/API only)
- **No regressions in performance, core features, or UX** — verify with `swift test`
  and `KittermBench` before calling work done; nothing that adds blocking I/O to the
  event loop or per-connection path

## Commands

`--help`/`-h`/`help` works after any command (`kitterm service install --help`
included) and exits before any side effect; `start`, `restart`, and
`service install` refuse an unknown flag the same way, exit 2, rather than
let `DaemonFlags.parse` silently drop it.

```bash
swift build
swift test
cd Web/terminal && pnpm install && pnpm build
swift run kitterm start|stop|status|restart
swift run kitterm statusline install         # wrap the Claude Code statusline so it posts the quota
swift run KittermBench                     # against a running daemon
./scripts/build-release.sh v0.1.0          # universal macOS tarball → dist/
./scripts/build-release-linux.sh v0.1.0    # static Linux tarball → dist/ (run on Linux)
```

On Linux only `swift build` works. `swift test` does not: several test files use
`Bundle(for:)`, which corelibs-XCTest lacks. `KittermBench` is excluded from Linux
builds entirely — it needs `URLSessionWebSocketTask`, absent from
corelibs-foundation — but it can measure a Linux daemon remotely with `--port`.
Check Linux with:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.1 \
  bash -c 'git config --global --add safe.directory "*"; swift build'
```

`KittermBench`'s `TUI-redraw` scenario is flaky — it intermittently reads ~193 B
instead of ~159 KB when it races shell startup. Re-run before treating it as a
regression.
