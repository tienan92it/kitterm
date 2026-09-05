# kitterm architecture

kitterm is a loopback terminal daemon. It serves an [xterm.js](https://xtermjs.org)
client over a local HTTP and WebSocket server, so a browser tab becomes a real shell
with a controlling TTY. The daemon is Swift and [SwiftNIO](https://github.com/apple/swift-nio).
No Node runs on the hot path.

This document describes the system for a contributor. It states the parts, the
session lifecycle, and the two data flows that carry most of the product value:
reconnect replay and program control. The source of truth for behaviour is
[`AGENTS.md`](../AGENTS.md); this document adds the shape.

## System overview

One process serves two kinds of client. A browser tab attaches over one WebSocket and
gets a shell. A program drives sessions over a read-mostly HTTP API. Both pass the same
access policy. Both reach the same `SessionRegistry`, which owns every `PtySession`.

![kitterm system architecture](diagrams/system-architecture.svg)

The design holds three properties.

- **One process, no terminal emulation.** The daemon never interprets screen state.
  The client owns the grid, the cursor, and every CSI or SGR sequence. The one bounded
  exception is `OscMarkScanner`. It matches OSC 133 and OSC 633 marks in the output
  stream, so an unwatched session still has a command index.
  A rendered screen exists for the foreman (`read_screen`), but the MCP bridge
  renders it in its own process from the raw tail the daemon serves. See ADR 0001
  (`adr/0001-read-screen-in-the-bridge.md`).
- **Durability by design.** Every output byte flows through a 4 MiB ring
  (`SessionLog`) with absolute stream offsets. A reconnect replays the exact bytes the
  client missed. State lives in `~/.kitterm/`, so a restart restores each pane.
- **Access by grade.** Loopback is trusted. `--lan` and reverse proxies require a
  token. A **full** token can do everything. A **watch** token can only observe.

### Components

| Component | File | Responsibility |
|---|---|---|
| `AccessPolicy` | `AccessPolicy.swift` | Validate Host and Origin; grade the token |
| WebSocket handler | `WebSocketSessionHandler.swift` | Attach a client; carry the binary protocol |
| `HTTPAPIHandler` | `HTTPAPIHandler.swift` | Serve the JSON and byte routes under `/api` |
| `SessionRegistry` | `SessionRegistry.swift` | Hold sessions; run linger and reap |
| `PtySession` | `PtySession.swift` | Own the shell master fd; batch output |
| `SessionLog` | `SessionLog.swift` | 4 MiB ring; absolute offsets; snapshot replay |
| `OscMarkScanner` | `OscMarkScanner.swift` | Index OSC 133/633 marks in the stream |
| `kitterm-spawn-helper` | `KittermSpawnHelper/main.c` | Give the shell a controlling TTY |
| `ScreenRenderer` | `KittermScreen/ScreenRenderer.swift` | Render a raw tail to a text grid, in the CLI only |

The spawn helper must sit beside the `kitterm` binary. A controlling TTY is required so
that `Ctrl+C` becomes `SIGINT`.

## Session lifecycle

A session lives from spawn to reap. The shell exit is a phase, not the end. This matters
for a program: a labelled session that a program made outlives its shell, so a crashed
orchestrator finds its work still reportable.

![kitterm session lifecycle](diagrams/session-lifecycle.svg)

The lifecycle holds four rules.

- **Detach, do not kill.** A dropped socket detaches the PTY. The shell keeps running.
  The client auto-reconnects with backoff and on focus, online, and visible events.
- **Two linger windows.** A browser session waits 300 seconds
  (`sessionDetachLingerSeconds`). A labelled session waits the linger window (3600
  seconds default, `orchestratedSessionLingerSeconds`, `--session-linger` to change).
- **Exit is reportable.** A labelled session that loses its shell is kept with
  `exited: true` and `exitCode`. Its `/commands` and retained output still answer. An
  unlabelled session is reaped as soon as its shell exits.
- **Reap cleans up.** Reap deletes the session's retained logs and dropped files.

`DELETE /api/sessions/<id>` ends a session and its shell now. It is the counterpart to
the long detach window. It is destructive, so it needs `--agent-control` and a full
token.

## Data flow: reconnect and replay

A transient disconnect must lose no output. The client counts the bytes it received. On
reconnect, it names the offset, and the daemon replays exactly the gap.

![Reconnect and exact-gap replay](diagrams/reconnect-sequence.svg)

The flow has three parts.

1. **Live.** `PtySession` appends every output byte to the ring at an absolute offset.
   The daemon batches the bytes to the client (about 2 ms or 64 KB). The client counts
   what it receives.
2. **Detached.** The socket drops. The WebSocket handler detaches the session but keeps
   reading the PTY. Output still appends to the ring. The ring rotates past 4 MiB. The
   read side never pauses.
3. **Reconnect.** The client reconnects with `?since=<offset>`. The handler sends an
   `S->C 8 logState` frame, then the exact gap bytes. When the offset is still in the
   ring, the resync bit is 0. When the offset rotated out, the daemon replays the full
   ring and sets the resync bit.

This property is what makes a reload or a sleep and wake lossless without any read-side
draining. A live upgrade extends the same idea across a binary swap; see
[live-upgrade.md](live-upgrade.md).

## Data flow: drive a shell from a program

A program tags a session, writes a command, blocks for the exit code, and reads the
output. This is the `execute()` contract that an agent framework wants. The three routes
map to write, wait, and read.

![Drive a shell from a program](diagrams/agent-drive-sequence.svg)

The contract has three routes.

- **Write.** `POST /api/sessions/<id>/input` types raw bytes into the shell. The caller
  includes its own `\n`, and sends `\x03` for `Ctrl-C`. This route needs
  `--agent-control`. It is capped at 64 KiB (`maxInputBytes`).
- **Wait.** `GET /api/sessions/<id>/commands/<n>/wait` holds the response until command
  `n` finishes (default 30 s, max 300 s, `commandWaitMaxSeconds`). It is read-only. A
  timeout is not an error; it answers `{running: true, timedOut: true}`, and the caller
  asks again.
- **Read.** `GET /api/sessions/<id>/commands/<n>/output` returns the command's bytes,
  capped at 256 KiB (`apiCommandOutputMaxBytes`, tail on overflow).

Two properties make this robust.

- **Stable command numbers.** `OscMarkScanner` indexes marks even when nobody watches
  the session. The `index` is stable for the session's life. An index that aged out of
  the mark window answers 410, not 404.
- **A named command.** Most shells emit OSC 133 marks but never say what ran. A command
  submitted through `POST /input` names the command it creates, so `command` is not null
  on a normal setup. A command line that the shell does report always wins.

## Security model

kitterm has no multi-user model. It serves shells as the user who runs it. Anyone who
can reach it has a shell. The controls below decide who can reach it.

- **Loopback by default.** The daemon binds `127.0.0.1` and validates Host and Origin
  against loopback names. This is the standard DNS-rebinding defence.
- **Two listeners, never one.** The plain listener stays on loopback. `--tls-cert` and
  `--tls-key` add an encrypted listener on `port+1`. When TLS is on, `--lan` no longer
  widens the plain listener, so TLS removes plaintext from the network.
- **`--trusted-host NAME`.** This names a public name that the daemon answers to behind
  a proxy. A request that names one is treated as remote and must present a token, even
  though the proxy connects from loopback. This stops the proxy from leaking loopback's
  trust.
- **Token grades.** A **full** token can do everything. A **watch** token can observe
  sessions and read the API, but can never type, take control, or open a shell. The
  WebSocket handler takes a watch-only path that cannot reach `spawnNew`. `POST /input`
  answers 403 for a watch token.
- **`--agent-control` is a separate switch.** It adds the one write route
  (`POST /input`). Default off. It stops a program from driving your shell; it is not
  about a person dropping a file into their own browser.

## The binary protocol

The client and the daemon speak a small binary protocol over the WebSocket
(`KittermProtocol`). The first byte is the opcode.

| Direction | Byte | Payload |
|---|---|---|
| C→S | `0` | UTF-8 or raw input |
| C→S | `1` | resize: `cols:u16 rows:u16` |
| C→S | `2` / `3` | pause / resume |
| C→S | `5` | requestControl: an observer takes over live |
| S→C | `0` | raw PTY output |
| S→C | `2` | session meta |
| S→C | `3` | cwd |
| S→C | `4` | exit code `i32` |
| S→C | `5` | session id (reattach key) |
| S→C | `7` | role: `0` controller, `1` observer |
| S→C | `8` | logState: resync flag, offset, replay length |

Opcode `4` from the client is deprecated. The daemon reads marks from the PTY stream
itself, so it ignores a client-sent mark to avoid double counting.

## State on disk

State lives in `~/.kitterm/`. The default port is 3418.

```
~/.kitterm/
├── pid, port                 daemon identity
├── token, token-watch        ephemeral LAN tokens (persist across restarts)
├── tokens.json               named tokens (SHA-256 hashes only)
├── profiles.json             named connect commands
├── server.log, lastlogin
├── recordings/               asciinema casts (--record)
├── logs/<session>.log        retained output (--retain-logs)
└── history/<key>             per-pane shell history
```

## Regenerate the diagrams

The diagrams come from JSON specifications in `docs/diagrams/`. The
[archify](https://github.com/tt-a1i/archify) tool renders and validates them. Each
`.svg` is the tool's own dual-theme export, so it needs no external font or stylesheet.

| Diagram | Specification | Type |
|---|---|---|
| System architecture | `diagrams/system.architecture.json` | architecture |
| Session lifecycle | `diagrams/session.lifecycle.json` | lifecycle |
| Reconnect and replay | `diagrams/reconnect.sequence.json` | sequence |
| Drive from a program | `diagrams/agent-drive.sequence.json` | sequence |

To validate and re-render one diagram, run the tool against its specification:

```sh
archify validate <type> docs/diagrams/<name>.json --quality showcase
archify deliver  <type> docs/diagrams/<name>.json docs/diagrams/<name>.html --quality showcase
```

The `.html` output is an interactive viewer. It has a theme switch, pan and zoom, and an
export menu. The committed `.svg` files come from that menu's dual-theme SVG export.
