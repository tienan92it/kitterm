# AGENTS.md — kitterm

Guidance for coding agents working in this repo.

## Product shape

- **Browser terminal only** — xterm.js client served by a Swift loopback daemon
- Tab open = new shell; session id in `sessionStorage` keeps "tab = shell"
- Transient disconnects (sleep/wake, reload) **detach** the PTY: every output byte flows through a per-session **4MiB ring with absolute stream offsets** (`SessionLog`) — detached reads never pause, the ring rotates. The client counts received bytes and reconnects with `?since=<offset>`; the daemon replays exactly the gap (or the full ring + a resync flag when the offset rotated out, announced via the `logState` frame). Client auto-reconnects with backoff + on focus/online/visible; unreattached sessions are reaped after 5 min (suspending clock)
- **Sessions are URLs**: `/?cwd=<path>` deep-links a new shell (`kitterm open <path>`); `/?session=<uuid>` joins a session — first client is controller, later ones are read-only observers (128KB replay tail, resize broadcast, share button copies the link); `/?hist=<key>` selects a per-pane history file. Observers get a "Take control" overlay (client opcode 5) — live handoff, no reconnect; the demoted side flashes "Another device took control" and keeps watching
- **Session profiles** (`SessionProfiles.swift`): `~/.kitterm/profiles.json` names connect commands (`ssh vm`, `docker exec …`). `/?profile=<name>` spawns a login shell and injects `command\n` as type-ahead input (pre-reader `PtySession.write`, flushed at adoption) — visible, echoed, in the pane's history; if the transport exits you land back in the local shell. The URL carries only the *name*; the command comes only from the file. Reattach ignores the param; a respawn after daemon restart re-runs it. Splits and ⌘⌥T inherit the profile. Fleet page (`/sessions`) shows a launcher (`GET /api/profiles`) and per-row profile chips; unknown names close 1008 with the reason. In-band OSC (133 marks, 9/777 notifications, OSC 7 cwd) flows through any transport, so remote shells stay fully legible — `kitterm integrate | ssh vm 'cat >> ~/.zshrc'` installs the snippet remotely
- **Split panes** (client): one browser tab holds a binary tree of panes (⌘D / ⌘⇧D split, ⌘⌥↑↓ / click focus, ⌘⌥T new browser tab in the focused pane's cwd). Layout + per-pane `{sessionId, cwd, histKey}` persist in `sessionStorage`; a reload restores the tree and reattaches each pane. Daemon is unchanged — N panes are just N WebSockets
- **Restart resilience**: the daemon polls each shell's cwd via `proc_pidinfo` (~2s, diff-gated) and pushes `cwd` frames, so a restored pane respawns where it was even when the shell emits no OSC 7. Each pane's `?hist=<key>` maps to `~/.kitterm/history/<key>` (set as `HISTFILE`, seeded once from the user's global history), so up-arrow survives a restart with that pane's own commands
- `--lan` binds 0.0.0.0 with token auth for non-loopback peers (`?token=` → cookie; `~/.kitterm/token`); loopback stays trusted. Tokens carry a **grade**: `full` (everything) or `watch` (observe + read API only — never input, never `requestControl`, never spawn; the WS handler takes a watch-only path that can't reach `spawnNew`, and `POST …/input` answers 403). Three token kinds: ephemeral control (`~/.kitterm/token`), ephemeral watch (`~/.kitterm/token-watch`, powers the 👁 watch-link share button via `/api/lan` `watchToken`), and named persistent tokens (`kitterm token create <name> [--watch]`, SHA-256 hashes only in `~/.kitterm/tokens.json`, mtime-cached reload so revocation needs no restart). The auth cookie is set to exactly the presented token — a watch token can never ride a full-access cookie
- `--record` writes asciinema v2 casts to `~/.kitterm/recordings/`
- **Session labels** (`/ws?label=run:abc,node:build`) tag a session so a fleet of shells is attributable to graph nodes. They also declare intent: a labelled session was made by a program, so the registry holds it for `orchestratedSessionLingerSeconds` (1h, `--session-linger`, capped at 24h and validated in `start` where the user can see the error) after its last client leaves instead of the browser's 5 minutes — an orchestrator that crashes and restarts finds its nodes still running. `SessionLabels` validates strictly; a malformed tag is dropped rather than failing the connection
- The LAN and watch tokens **persist across restarts** (`~/.kitterm/{token,watch-token}`, 0600). They used to be minted every start, which revoked every share link whenever the daemon came back — including for a routine restart or upgrade, at the moment you are least likely to be at the machine that could print you a new one. A stored token is only trusted if it is owner-readable and looks like one this daemon wrote; anything else is replaced, so a damaged credential fails closed. `--rotate-token` is how you revoke
- `--retain-logs` spills each session's output to `~/.kitterm/logs/<id>.log` (0600, 64 MiB cap, rotating, deleted when the session is reaped) so `/commands/<n>/output` still answers for ranges the 4 MiB ring dropped. **Off by default** — shell output on disk, same reason `--record` is opt-in. All I/O is a `queue.async` hand-off, never awaited on the loop. **The file does not start at stream offset 0** (a shell prints before the session has an id to name a file after), so `SessionLogStore` tracks an `origin` and translates; assuming otherwise returns plausible wrong bytes
- Tab title is per-session (custom name + optional cwd folder), stored per session id; observers adopt the controller's title and cannot edit it. A session created or renamed over the API carries a **server-side name** (`POST/PATCH /api/sessions`), pushed on the `title` opcode; it fills in the tab title when the client has no custom name of its own (the local name still wins)
- `kitterm service install` runs the daemon from a per-user LaunchAgent — see **Service** below
- **The daemon does not emulate a terminal.** No grid, no cursor, no CSI/SGR, no character sets — screen state is entirely the client's business. The one bounded exception is `OscMarkScanner`, which matches OSC 133/633 in the output stream so shell-integration marks exist for sessions nobody is watching (an orchestrator-driven session used to record none, leaving `/api/sessions` state, `lastExit` and `/commands` empty). It scans for two ids and their terminators and nothing else; it runs outside `stateLock` on the event loop, and its cost is below KittermBench's noise floor because it `memchr`s for `ESC` rather than walking bytes
- **No Node on the hot path** (daemon is Swift + NIO)
- No native Mac app
- PTY spawn uses `kitterm-spawn-helper` (must be beside `kitterm`) so the shell gets a controlling TTY — required for Ctrl+C → SIGINT

## Binary protocol (`KittermProtocol`)

| Dir | Byte | Payload |
|-----|------|---------|
| C→S | `0` | UTF-8 / raw input |
| C→S | `1` | `cols:u16` `rows:u16` (big-endian) |
| C→S | `2` / `3` | pause / resume (empty) |
| C→S | `4` | mark — **deprecated and ignored.** The daemon reads marks out of the PTY stream itself (`OscMarkScanner`), so an unwatched session still has an index; accepting these too would double every mark for an older client still sending them. Payload kept in the codec for old clients: `kind:u8` (0 A, 1 B, 2 C, 3 D) `exit:i32` BE (Int32.min = absent) `offset:u64` BE `cmdline:utf8` (≤2KiB) |
| C→S | `5` | requestControl (empty) — an observer takes over: the current controller is demoted to observer, both get fresh `role` frames. The whole swap runs in one event-loop tick (`ControlHandoff`, loop-confined), so no output/input can interleave mid-swap; the promoted side attaches `.sinceOffset(logHead)` = zero replay |
| S→C | `0` | raw PTY output |
| S→C | `1` | title UTF-8 |
| S→C | `2` | session meta (length-prefixed fields) |
| S→C | `3` | cwd UTF-8 |
| S→C | `4` | exit code `i32` BE |
| S→C | `5` | session id UTF-8 (reattach via `/ws?session=<uuid>`) |
| S→C | `6` | resize `cols:u16 rows:u16` BE (observer follows controller size) |
| S→C | `7` | role `u8` (0 controller, 1 observer) |
| S→C | `8` | logState `flags:u8` (bit0 resync) `offset:u64` `replayLen:u64` BE — sent once per attach, before any replayed output |

Flow-control defaults: ~2ms / 64KB batching, PTY pause at 4MB buffered outbound, resume at 1MB, hard close at 64MB.

## HTTP API (JSON off the I/O stream; read-only unless noted)

- `GET /api/health`, `GET /api/lan`, `GET /api/sessions` (mark-derived state per session; `?label=run:abc` filters, and each row carries its `labels`, its `name` and `note` when set; a filter that is not `key:value` is a 400, because an empty list would read as "that run has no sessions"). Each row also carries a **`mergedState`** — the crew vocabulary `working / needs-approval / needs-input / completed / failed / idle / exited / unknown` — plus `agent {status, message?, at}` (the session's latest hook report), `pendingApproval`, and `lastOutputAt`. `mergedState` is `MergedSessionState.merge`: after the two hard facts (`exited`, `needs-approval`) **the newer evidence source wins** — the latest hook report or the latest state-bearing mark. That is what makes a shell running `claude` work: its marks say "running" for hours (one preExec, no commandEnd until claude exits), every hook report is newer, so `working`/`needs-input`/`completed` track the agent's real turns; a human's later command produces newer marks, which then win. Never a state machine the daemon advances, so a session with no Claude hooks collapses to the exact `running/idle/unknown` (`state`, still sent) it always had. `lastOutputAt` is a fact for a caller's own "stuck" judgment; the daemon ships no such judgment itself
- `POST /api/sessions` — **spawn a session from JSON**, the programmatic counterpart of opening a tab. Body `{cwd?, profile?, labels?, name?, note?, cols?, rows?, input?}`; `input` is typed into the shell at its first read after any profile command, so `{"input":"claude\n"}` spawns an agent in one call. Answers 201 `{ok,id,name,wsPath,pagePath}` — **paths, not URLs**, because `/api/lan` owns external-URL construction and a duplicated rule is a stale link. 400 for an unknown profile, a non-directory cwd, or a malformed name/note/label (mirrors the WS 1008 reasons); 503 at `maxConcurrentSessions`. **The one route that creates a shell from a request body**, so it sits behind `--agent-control` + full grade like the input route — strictly more powerful than typing into an existing shell. An API-spawned session is **orchestrated by construction** (no label needed): the 1h linger holds it, and it survives its shell's exit with `exited`/`exitCode`, killed via `DELETE`. It starts **detached**, so the first browser to open its link is its controller
- `GET /api/sessions/<id>` — one session's listing row (the list-row shape plus `note`), for a deep-read without fetching the whole fleet. Read-only
- `PATCH /api/sessions/<id>` — update `{name?, note?, labels?}`; an empty name clears it. **Full grade, no `--agent-control`**: metadata does not drive a shell, the same reason approval decisions sit outside the flag. A rename rides the long-dormant `title` opcode to every attached client, so open tabs follow without a reload; a client with its own custom name keeps it
- `GET /api/events?since=<seq>&timeout=<s>&session=<id>` — the **daemon-wide control-plane feed**, so a foreman watching a dozen crew sessions holds one parked request instead of polling `/api/sessions` for each. Returns events newer than `since` at once, or parks until one arrives (the `/commands/<n>/wait` shape — one loop, no streaming machinery), answering `{ok, events, next, pruned}`. `next` is the cursor to poll with; `pruned` is true when `since` aged out of the bounded ring (the `/commands` 410-honesty, without killing the poll loop). Read-only, any grade — observing what agents do. v1 event types: `session.created/renamed/exited/removed`, `agent.status`, `approval.pending/resolved`, `note`. The feed is `NIOLock`-guarded, not loop-confined: `SessionRegistry` (an actor) appends lifecycle events from off-loop, and completing a parked promise cross-thread is NIO-safe. Read-or-park happens under one lock (`EventLog.poll`), so an off-loop append cannot land between "nothing yet" and "park me" and strand the request; a `since` past the head answers at once with the true `next` rather than parking to its deadline. Waiters are capped daemon-wide (503 past the ceiling) and the timeout ceiling is `eventWaitMaxSeconds` (60), lower than a command wait's, because this route is any-grade
- `POST /api/sessions/<id>/events` — a crew agent posts a structured `note` ("plan ready for review") that lands on the feed and wakes a parked poll. The counterpart to `/api/hooks`: an agent *reporting*, not driving, so full grade **without** `--agent-control`. `{message, data?}`, message capped
- `GET /api/sessions/<id>/marks` — the raw shell-integration marks
- `GET /api/sessions/<id>/commands` — commands paired from marks: `{index, command, exit, startOffset, endOffset, running, startedAt, endedAt, durationMs, outputUrl}`. **`index` is stable for the session's life**: the mark window is bounded, so `SessionMarkStore` counts what it drops and numbering continues from there rather than restarting at 1 — otherwise a caller's saved index or `outputUrl` would silently come to mean a different command. An index below the window answers **410**, not 404. The timings and URL exist so a **caller can hang its own span on a command** — kitterm emits no traces, because whoever called it owns the trace context. Pass `traceparent:<w3c>` as a label and it comes back on every row, which is all the correlation a tracer needs
- `GET /api/sessions/<id>/commands/<n>/wait?timeout=<s>` — hold the response until command `n` finishes (default 30s, max 300). With the input route this is the `execute()` contract every agent framework wants: write a command, block for its exit code, read its output. Read-only, so no `--agent-control`. A timeout is **not** an error — `{running:true,timedOut:true}`, ask again. Waiting on a command that has not started yet is legitimate. Waiters are capped per session (503 past it). An index that has aged out of the mark window answers 410 rather than blocking until its deadline
- A command submitted through `POST /input` **names the command it creates** when the shell does not. Only kitterm's snippet and VS Code emit the command line (OSC 633;E); a shell carrying iTerm2's or Powerlevel10k's OSC 133 marks every command but never says what it was, so without this `command` is null on most real setups. A command line the shell *does* report always wins
- A **labelled session outlives its shell**: when the shell exits, the session is kept for the linger window with `exited: true` and `exitCode`, so `/commands` and retained output still answer — a node that crashed is the one worth inspecting. It cannot be attached to, and reading it does not reap it. An unlabelled (browser) session still goes immediately. A shell that dies mid-command closes that command with the shell's own exit code, so a waiter gets an answer instead of a command that runs forever
- `GET /api/files?path=<dir>&session=<id>` — list a directory so a caller can pick a file **or folder** and insert its **real path**, with no copy. This is the counterpart to dropping: a browser never reveals where a dragged file came from, so a drop must copy and the agent then edits the copy — browsing has no such problem, and a folder is just a path. Relative paths resolve against the session's cwd, `~` expands. Full grade only, which is the whole access story: anyone who can reach it can already type `ls`, and the daemon runs as the user, so the OS decides what is readable. Watch-only callers cannot type, so they cannot browse. No allowlist by design
- `POST /api/sessions/<id>/files` — save a file dropped into a session and answer with the path it landed at (`~/.kitterm/drops/<session>/<name>`, 0600, removed when the session is reaped). A coding agent takes context as paths, not uploads, so the browser drops a file and inserts the path at the cursor — never with a newline, so nothing runs on its own. Full grade, no `--agent-control`: that flag stops a *program* driving your shell, and this is a person dropping a file into their own browser. The name arrives in `X-Kitterm-Filename` and is rewritten (leaf component only, `[A-Za-z0-9._-]`), so the bytes can only land in kitterm's own directory. 16 MiB cap, buffered before writing
- `DELETE /api/sessions/<id>` — end a session and its shell now, the counterpart to the long detach window a labelled session gets. Destructive, so `--agent-control` + full grade, like the input route
- `GET /api/sessions/<id>/commands/<n>/output` — raw output bytes of command `n` (`application/octet-stream`), capped at `apiCommandOutputMaxBytes` (256KiB, tail on overflow); `X-Kitterm-Total-Bytes` / `-Truncated` / `-Pruned` headers. Precise for substantial output; tiny single-frame commands collapse to an empty range (see `SessionCommands`)
- `POST /api/hooks` — **an agent asks a human, and reports on itself.** A Claude Code `"type": "http"` hook posts its event here; for `PreToolUse` the daemon **holds the response** until someone allows or denies, and the verdict travels back in the body (`hookSpecificOutput.permissionDecision`) — status codes cannot block a tool call, only the JSON can. This is the one route that answers slowly on purpose, reusing the `commands/<n>/wait` machinery so nothing blocks the loop. **No decision is an answer**: on expiry it replies `{}`, and the agent falls back to asking in its own pane, so an unattended agent is never wedged. The pane is named by `X-Kitterm-Session`, which the hook config reads from `KITTERM_SESSION_ID` — exported into every shell the daemon spawns, because a hook config is static and cannot look it up. `Notification` and `Stop` events do not block: `Notification` records the session's status as `needs-input` (carrying its `message`), `Stop` records `completed`, and both answer `{}` at once; `PreToolUse` records `working` before it holds — the edge that clears a stale `needs-input` once the human answered and the agent moved on. The status lives on the `PtySession` (its lifetime is the session's) — that is the `agent`/`mergedState` a `/api/sessions` row then shows. Unknown events answer `{}` and record nothing, so an over-broad config and a schema change both degrade to "no opinion". **Full grade only** now: the URL is always loopback (the agent runs on the daemon's own machine), so this refuses nothing real, but once these events drive a status the fleet view trusts, an ungated route would let a watch caller spoof `completed` on any session. `kitterm hooks` prints the config (`PreToolUse`, `Notification`, `Stop`)
- `GET /api/approvals` / `POST /api/approvals/<id>` — what is waiting, and the answer (`{"decision":"allow"|"deny","reason":"…"}`). **Deciding is full grade only**: a watch token exists precisely to withhold it, and this gates on grade rather than `--agent-control` because that flag is about a *program* driving a shell while this is a person answering a question. 404 covers unknown, already-answered and expired alike — from outside they all mean "too late"
- `POST /api/sessions/<id>/input` — **write.** The request body is raw bytes typed into the shell (include your own `\n`; send `\x03` for Ctrl-C). Capped at `maxInputBytes` (64KiB → 413). Returns `{ok,bytes}`; 404 unknown session, 409 closed. **Off unless the daemon was started with `--agent-control`** (else 403). Input interleaves with any attached controller — no separate role

## Security

- Bind `127.0.0.1` by default; `--lan` is the only path that widens it (0.0.0.0 + token auth)
- Enforce Host / Origin against loopback hostnames
- No multi-user model — shells run as the invoking user
- **Two listeners, never one.** The plain listener stays on loopback (unchanged pipeline, no TLS handler, so local latency and `kitterm open`'s `kitterm.localhost` URL are exactly as before — and `*.localhost` is already a browser secure context). `--tls-cert/--tls-key` add an encrypted listener on `port+1` (`--tls-port` to override) bound to `0.0.0.0`; when TLS is on, `--lan` no longer widens the plain one, so enabling TLS *removes* plaintext from the network. kitterm never generates certificates — self-signed trains click-through and iOS refuses `wss://` to an untrusted cert; `tailscale cert` is the documented source
- **`--trusted-host NAME`** (repeatable) = the public names the daemon answers to behind a proxy or overlay. **A request naming one is treated as remote and must present a token even though the proxy connects from loopback** — otherwise the proxy would leak loopback's unauthenticated full access. Verified live against `tailscale serve`: it forwards the original `Host` (so the rule fires — a tokenless request through the proxy gets 403, not local trust) and sends `X-Forwarded-Proto: https` (so the cookie gets `Secure`); the WebSocket upgrade survives the proxy. `AccessPolicy.isLoopback` always uses the real socket peer. `X-Forwarded-For` is deliberately not parsed (nothing needs client IPs; parsing it only adds a spoofing class); `X-Forwarded-Proto` is honoured *only* to decide the cookie's `Secure` flag, only from loopback peers, never for an access decision
- **`/api/lan`** reports the external base URL (TLS name+port, else proxy name, else LAN IP), which is what the ⧉ and 👁 share buttons build links from — the client needs no scheme logic (`defaultWsUrl()` derives `wss://` from `location.protocol`)
- The `/api/sessions/<id>/…` GET routes expose command lines and command **output** behind the same single access policy — anyone the policy admits can read what ran, and what it printed, in any session
- `--agent-control` adds the one write route (`POST …/input`). It sits behind the same access policy, so on a loopback daemon any local process can then drive any shell as your user; on `--lan` the token still gates it. Default off — enabling it is an explicit trust decision
- `/api/profiles` exposes profile commands behind the same policy; profile *names* from URLs are only ever looked up in the user-authored file, never executed directly

## State

`~/.kitterm/{pid,port,token,token-watch,tokens.json,server.log,lastlogin,profiles.json}`
plus `recordings/`, `logs/<session>.log` (`--retain-logs`) and `history/<key>` (per-pane) —
default port **3418**.

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

## Coding standards

- Single responsibility per file/type
- KISS: simplest working solution first
- Do not copy large copyrighted chunks from ttyd / localterm
- Keep JSON off the I/O stream (health/API only)
- **No regressions in performance, core features, or UX** — verify with `swift test`
  and `KittermBench` before calling work done; nothing that adds blocking I/O to the
  event loop or per-connection path

## Commands

```bash
swift build
swift test
cd Web/terminal && pnpm install && pnpm build
swift run kitterm start|stop|status|restart
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
