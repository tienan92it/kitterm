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
- **The clock reaps an idle shell, not a working session.** At the end of its window a
  labelled session gets a fresh window when a program other than the shell holds the
  terminal, or when output arrived during the window (ADR 0002). A foreman never
  attaches, so this is what keeps a crew session alive while it works. A labelled
  shell at its prompt that printed nothing for a whole window is reaped. A browser
  session is reaped at its window whatever the shell is doing.
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
  `--agent-control`. It is capped at 64 KiB (`maxInputBytes`). A body over 1 KiB is
  refused with 409 while a cooked reader holds the terminal, because the kernel cuts a
  canonical-mode line there; `?force=1` overrides (ADR 0003).
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
  trust. Set it whenever a proxy fronts the daemon. Without it, `--lan` makes the daemon
  read the proxy's loopback connection as local and skip the token
  ([Reaching the daemon from a phone](#reaching-the-daemon-from-a-phone)).
- **Token grades.** A **full** token can do everything. A **watch** token can observe
  sessions and read the API, but can never type, take control, or open a shell. The
  WebSocket handler takes a watch-only path that cannot reach `spawnNew`. `POST /input`
  answers 403 for a watch token.
- **`--agent-control` is a separate switch.** It adds the one write route
  (`POST /input`). Default off. It stops a program from driving your shell; it is not
  about a person dropping a file into their own browser.

## Reaching the daemon from a phone

A phone needs a secure context. A browser registers a service worker only over HTTPS
with a certificate that validates against the device's trust store, or on `localhost`.
A self-signed certificate does not qualify, so the transport decides whether the fleet
view can ever notify a phone.

**kitterm fronts the daemon with `tailscale serve` and requires `--trusted-host`.** The
tailnet issues a publicly trusted certificate for the machine's MagicDNS name.
`tailscaled` terminates TLS and proxies to the plain loopback listener. The phone
installs no certificate, and nothing reaches the public internet.

The human runs two commands once:

```
tailscale serve --bg --https=443 http://127.0.0.1:3418
kitterm restart --trusted-host <machine>.<tailnet>.ts.net
```

The phone then opens `https://<machine>.<tailnet>.ts.net/sessions.html?token=…` once.
The daemon sets the auth cookie, so later visits carry no token in the URL.

### Consequences

- **The origin carries no port.** It survives a daemon restart, a port change and a
  live upgrade. A service worker registration and a push subscription outlive all
  three, because the browser keys both to the origin.
- **`tailscaled` owns the certificate and renews it.** kitterm reads no private key on
  this path, and `--tls-cert` stays unused.
- **`--trusted-host` is not optional.** The proxy connects from loopback. Without the
  flag, and with `--lan`, the daemon reads that peer as local and grants full access to
  the whole tailnet with no token. That would defeat both the token grades and
  `--agent-control`. With the flag, the request is remote and must present a token.
- **`tailscale serve` injects `Tailscale-User-*` headers.** kitterm ignores them. The
  token remains the only credential.
- **The cost: the tailnet becomes a dependency.** The MagicDNS name does not resolve on
  a public resolver, and the `100.64.0.0/10` address does not route. A phone off the
  tailnet cannot open the page at all.
- **The option closed: a phone on the LAN with no Tailscale.** That phone needs the
  daemon's own TLS listener instead.

The daemon's own listener (`--lan --tls-cert --tls-key`) stays supported and reaches a
LAN phone. It costs more to keep: `tailscale cert` on macOS runs sandboxed and writes
only inside `~/Library/Containers/io.tailscale.ipn.macos/Data`, so every renewal is a
copy, a `chmod 600` and a daemon restart. `NIOSSLContext` loads the files once in
`DaemonServer.start()`. The origin also carries the TLS port, so changing `--tls-port`
discards every registration on every phone.

### The subscription the daemon keeps

`POST /api/push/subscriptions` stores the browser's own `PushSubscription.toJSON()`
(`{endpoint, keys: {p256dh, auth}}`) in `~/.kitterm/push.json`; `DELETE` with
`{endpoint}` forgets it. Both are full grade only, with no `--agent-control`: a
person registers their own phone, and a watch token exists to withhold the answer,
so it does not get the question either. The store (`PushSubscriptionStore`) keeps
one entry per endpoint. A second post of the same endpoint replaces its keys and
answers `200` where the first answered `201`, because the page cannot know whether
the daemon still holds its subscription and posts on every load. The file is
`0600`, versioned like `last-run.json`, and holds nothing but the endpoint, its two
keys, and when it was first stored: no session, no project, no token. A subscription
names a browser; the message that names a session is composed at send time.

Every run builds the store from the file, so the subscription is known again after
a restart and after a live upgrade, whose successor reads the same file rather than
carrying it through `TakeoverState`. When a push service answers `410 Gone`, the
sender removes the endpoint with the same call `DELETE` uses; the store does not
watch for it, because the sender is the one that sees the answer.

### The message the daemon sends

`PushNotifier` sends one message per subscription when a session enters
`needs-input`, `needs-approval` or `failed`, and nothing for `working`, `idle`,
`completed`, `exited` or `unknown`. The message is an RFC 8291 `aes128gcm` body
sealed for one browser's keys, with a VAPID token (RFC 8292) signed over the
endpoint's origin. The payload names the session, its state, the row's name and
project, the reason (the hook's message, the tool that waits, or `exit N: <command>`),
a composed `title` and `body`, and `url: /?session=<id>`. `TTL` is one hour and
`Urgency` is `high`.

**Where the transition is observed.** The daemon never advances a state machine.
`mergedState` is computed at read time from a hook report, a pending approval and the
shell's marks, so no one place knows the merged state changed. The notifier is told at
each place the evidence changes, and it remembers the last state per session. That
memory turns "the evidence changed" into "the state changed":

- `HTTPAPIHandler.emitAgentStatus`, which already fires only on a hook transition,
  and the `approval.pending` append and the held decision's completion, answered or
  expired. Each hands over `MergedSessionState.merge` computed exactly as the row
  computes it, with the approval store read on the loop.
- `PtySession.setCommandEndHandler`, which the registry sets on every session it
  admits (`SessionRegistryObserver`). A `commandEnd` mark with a non-zero exit is
  `failed`; that state had no event before, and this handler fires once per command,
  off the lock, so the byte path pays nothing for prompt marks.

**One per transition.** The same state again is silent, whatever the hook's words. A
transition out of an actionable state resets the memory, so the next `needs-input` is
a message again. The memory lives in this process only. A restart ends every shell, so
nothing that was waiting exists to be told about twice. A live upgrade restores each
session's last hook report, which gates the `agent.status` transition at its source, so
an unchanged state is silent before it reaches the notifier.

**Rate limit.** At most 4 messages per session per 60 seconds. A message past the
limit is dropped and logged, not queued: a human told four times in a minute that one
session needs them is looking at it already, and a queue would deliver a state the
session has left.

**Off the loop.** `observe` takes a lock, updates two dictionaries and starts a `Task`.
The session lookup, the encryption and the HTTP round trip run in that task. A push
service that answers `404` or `410` has forgotten the subscription for good (RFC 8030),
and the notifier forgets it through the same `remove(endpoint:)` that `DELETE` uses.

**The VAPID pair.** `~/.kitterm/vapid.json` holds the P-256 private key at `0600`, in
its own file because it is a daemon secret and `push.json` holds only what the browser
handed the page. A browser binds its subscription to the public key it subscribed with,
so a fresh pair per run would make every stored subscription answer `403` after the
first restart. The pair is generated once, and a file that is not owner-only is
replaced and the replacement logged, because it invalidates every subscription on
every phone. The page reads the public key from `GET /api/push/vapid` when it
subscribes.

Measured on the live feed on 2026-09-11: Claude Code sends `Stop` and then a
`Notification` 60 seconds later when nobody answers, so a finished turn becomes one
message after a minute of silence. No `Notification` arrived beside a held
`PermissionRequest`, so one question is one message.

### The page asks, and says

The fleet view carries one switch under its head, `Notify this device`, with the
reason beside it when pressing it could not work. `pushToggle` in `sessions-model.ts`
decides the switch from what the page knows: the token's grade, whether the origin is
secure and the browser has `PushManager`, `Notification.permission`, whether the
daemon holds the subscription, and whether a change is in flight. `sessions.ts` only
paints it, under one `data-focus` key, so a repaint gives focus back.

- **Hidden for a watch client.** The switch is not disabled but absent, because the
  daemon would refuse the subscription and the page should not offer what it will
  refuse.
- **Disabled, with the reason, where pressing it could not work**: no push in this
  browser (iOS wants the page on the Home Screen first), an http origin, a daemon
  before the vapid route, and `denied`. `denied` is the state that matters most: the
  browser asks once and never again, so the line says the site's notifications are
  blocked and points at the browser's site settings, rather than leaving a switch
  that does nothing.
- **On and off** otherwise. On asks the browser first, inside the tap, then registers
  the worker, reads the key, subscribes with `userVisibleOnly` and posts the
  subscription. Off tells the daemon first, while the endpoint is still known, and
  then drops the browser's side either way, because an endpoint the browser gave up
  answers the daemon `410` and the daemon forgets it. The page re-posts a held
  subscription on every load, which the store answers `200` for, and a subscription
  bound to another key than the daemon's is dropped and made again.

**`GET /api/push/vapid`** answers `{ok, publicKey}`, the `applicationServerKey`. It is
full grade only, and not because the key is secret: it rides in the `k=` of every
message and the push service hands it to any browser. The gate is the feature's
boundary. A watch client cannot subscribe, so a key would only let its page build a
subscription the daemon then refuses, after asking the browser for a permission the
page cannot take back.

**The service worker** is `Web/terminal/public/sw.js`, copied into the bundle unbuilt
and served at `/sw.js` from the web root, which is what gives it the scope `/` and
control of `/sessions` and `/`. A worker served under a path controls only that path.
It is plain JS with no imports, because a worker registered without `type: "module"`
cannot import and a hashed bundle name would change its URL on every build. On `push`
it shows the daemon's `title` and `body` as they are, tagged `session:<id>` so a later
message about the same session replaces the earlier one, with `url` in the
notification's data. On `notificationclick` it opens `/?session=<id>` on this origin,
focusing a window already there and opening one otherwise, which is the case when the
page is closed; a URL on another origin, or none, opens `/sessions`. `sw.test.ts` runs
the file in a fake `self`.

**Measured on 2026-09-11** against a scratch daemon behind `tailscale serve` with
`--trusted-host`, from Google Chrome 152 driven by Playwright with the notification
permission granted on the context, which is what round 1's headless run could not do.
`pushManager.subscribe` returned a real `fcm.googleapis.com` endpoint. Corpus request
`01-phone-walks-away`: one notification `alpha needs input` / `kitterm · Claude needs
your permission to use Bash` 400 ms after the `Notification` hook, nothing more in the
next 84 seconds, one `beta needs approval` / `kitterm · Bash` 160 ms after the held
`PermissionRequest`, nothing for `PreToolUse`, `Stop` or the approval's answer, read
back from `registration.getNotifications()`. `push.json` held one subscription at
`0600`. A watch client saw no switch and got `403` from both routes. After the switch
was turned off the file was empty and a fresh `needs-input` produced nothing. The tap
itself was not automated: a notification is the OS's to click, so the pane it opens is
proved by the notification's `data.url` and by `sw.test.ts`, not by a driven click.

### The measurement that settled it

Measured on 2026-09-11 against a scratch daemon under `KITTERM_STATE_DIR`, on
`genos-pro.tail66794d.ts.net`, with Chromium driven from this machine.

- Both routes give a real secure context. `curl` with no `-k` reported
  `ssl_verify_result=0` and TLSv1.3, and the page reported `isSecureContext: true`.
  `navigator.serviceWorker.register('/sw.js')` reached `activated`, and after a reload
  with no token in the URL the registration still controlled the page. `PushManager`
  was present on both. `tailscale serve` also proxied the `/ws` upgrade.
- The certificate is a 90-day Let's Encrypt certificate for the MagicDNS name only.
  `tailscale cert` writes the key `0600` and renews only when it is called.
- `dig @1.1.1.1 <machine>.<tailnet>.ts.net` returned nothing; the tailnet resolver
  returned the `100.x` address.
- Behind `tailscale serve`, `GET /api/sessions` with no token answered: `200` and full
  access with `--lan` and no `--trusted-host`; `403 non-loopback Host` with neither
  flag; `403 missing or invalid token` with `--trusted-host`, with or without `--lan`.
  A full token then answered `200`.

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
├── server.log
├── token, token-watch        ephemeral LAN tokens (persist across restarts)
├── tokens.json               named tokens (SHA-256 hashes only)
├── recordings/               asciinema casts (--record)
├── drops/<session>/<name>    files dropped into a session from the browser
├── lastlogin                 timestamp of the previous session
├── profiles.json             named connect commands
├── projects.json             registered projects (kitterm project add|init)
├── logs/<session>.log        retained output (--retain-logs)
├── history/<key>             per-pane shell history
├── archive/<id>/             archived sessions (archive.json, output.log)
├── respawn.json              names and labels of live sessions, for a respawn
├── last-run.json             how the last run ended, or nothing where its end should be
├── push.json                 Web Push subscriptions, one per browser endpoint (0600)
├── vapid.json                the VAPID key pair every subscription is bound to (0600)
├── takeover/                 live-upgrade handoff, between execv and adoption
└── web-root                  the web bundle the running daemon pinned
```

The order is the order `DaemonPaths.swift` declares them.

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
