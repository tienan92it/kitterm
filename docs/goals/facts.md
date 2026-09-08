# Facts

Decisions and measurements that a later round must not rediscover. One entry
per fact. Newest first. Each entry names its date and its source. A foreman
appends; a human prunes. Move a fact that becomes a rule into `LOOP.md`. Move
a fact that becomes a design decision into `docs/adr/`.

## Project resolution (2026-09-08, round 1)

- A registered root that is a parent of a git checkout swallows that
  checkout's sessions: a registered prefix beats the git walk. Round 2
  registered `/Users/antran/Workspace` and lost the kitterm card until
  kitterm was registered too. A proposal to reverse the order is in
  `rounds/002.md`.
- The kernel reports a shell's cwd as a real path, `/private/var/…` on
  macOS. Foundation's `resolvingSymlinksInPath()` keeps `/var/…`, so a
  registered root canonicalized with it never matches. `realpath(3)` gives
  the kernel's form. `Projects.canonicalRoot` uses it.
- `PtySession`'s cwd poll runs only while a controller is attached. A
  detached crew session keeps a stale value from any poll-driven field, so
  a row-time check against the kernel cwd is needed for a detached session.
- `Tests/KittermCLITests/MCPToolsTests.swift:18` pins the MCP tool count.
  Every new tool changes that line.

## Fleet view and session model (2026-09-08, code survey for this goal)

- `Web/terminal/src/sessions.ts` renders rows in the daemon's order, which is
  UUID order (`SessionRegistry.swift:201-205`). The page has no group, sort,
  filter, or search.
- The page never reads `labels`, `cols`, `rows`, `exited`, or `exitCode`,
  although `sessionItem()` sends them (`HTTPAPIHandler.swift:614-677`).
- Kill, archive, and spawn are absent from the page. The routes exist:
  `DELETE /api/sessions/<id>`, `POST /api/sessions/<id>/archive`,
  `POST /api/sessions`.
- No link to `/sessions` exists in the terminal UI. A user types the URL.
- `sessions.ts` runs on import and has no test. Only `approval-format.ts` is
  tested, and it was split out for that reason (`approval-format.ts:1-7`).
  Put new page logic in a pure module with tests.
- The page polls `/api/sessions`, `/api/approvals`, and `/api/archives`
  every 2 s and holds one `/api/events` long-poll as a repaint trigger.
- A `note` from `post_note` lives only in the 1024-event ring
  (`EventLog.swift`). A daemon restart drops it. The round record is the
  durable copy.
- The only grouping primitive is `SessionLabels`, a flat map, with a
  `key:value` filter on `GET /api/sessions?label=`. The reserved key is
  `traceparent`. The conventions `crew:`, `task:`, `resumed-from:` are
  documentation only.
- Archives live at `~/.kitterm/archive/<id>/`, singular `archive`.
  `archive.json` keeps the labels, so an archive stays attributable.
- `docs/foreman.md` lists 13 tools; `MCPTools.swift` has 15
  (`archive_session`, `list_archives` are missing from the doc).
- `docs/architecture.md` "State on disk" omits `archive/`, `drops/`,
  `respawn.json`, and `web-root`. `DaemonPaths.swift` is the canonical list.
- The installed skills in `~/.claude/skills/` are older than
  `examples/foreman/`. The installed `foreman-loop` respawns a whole crew
  after `kitterm upgrade --live`; the repo copy does not.

## Typing into a crew pane (2026-09-04 to 2026-09-07, foreman sessions)

- Since v0.20.0 (#59) `send_input` with `enter:true` presses Enter the way
  the reader expects: `\n` for a shell, a 100 ms settle then `\r` for a
  program. Before that, Claude Code kept the newline as text.
- Since v0.21.1 (#65) the daemon types a body into a program in 512-byte
  pieces 50 ms apart. Before that, Claude Code kept only the last read of a
  fast paste: 59 of 2104 bytes on 2.1.260, 16 of 8193 on 2.1.263. A 64 KiB
  body takes about 6.5 s. Send one prompt in one call; never split it.
- Since v0.21.2 (#66) a body over 1024 bytes into a cooked reader answers
  409 with `foregroundProgram` in the reason. Darwin keeps 1024 bytes of a
  canonical line; Linux keeps 4095. `force:true` overrides.
- Since v0.20.0 (#58) `read_screen` renders the pane and marks dim runs
  `{dim}…{/dim}`. An empty Claude Code prompt shows a dim ghost suggestion
  that reads as typed text in the raw tail. Read the screen before and after
  every `send_input` into a TUI.
- A pane spawned in a folder Claude Code has not trusted shows the
  folder-trust dialog. A task typed into that dialog is lost.
- `claude --resume` needs the full transcript UUID. A prefix opens the
  picker, which finds nothing in a worktree cwd.
- Since v0.22.0 (#68) `kitterm upgrade --live` keeps sessions, ids, and the
  event `epoch`. Verified 2026-09-07 with a claude pane that answered before
  and after.

## Waking a foreman (2026-09-06, foreman session)

- A foreman that runs as a background job wakes only when a background
  command exits. A one-shot shell loop that polls `GET /api/sessions` every
  10 s, exits on a state change, and exits on its own after about 560 s is
  the pattern that works. The harness ceiling is 600 s and a timeout kill
  does not always notify.
- Every earlier watcher failed silently because its Python used
  `print(f"{s.get(\"name\")}")`, a backslash inside an f-string expression,
  which this machine's Python rejects. Arm a watcher against a state that
  already exists and confirm it exits at once before you trust it.

## Toolchain (2026-09-04, foreman plan)

- A live check of the CLI must run `.build/debug/kitterm` (fresh after
  `swift test`), because `swift run` needs `Package.swift` in the cwd and
  a temp project directory has none. `KITTERM_STATE_DIR` isolates the
  state; `project init` needs no spawn helper.
- The web package manager is pnpm (`pnpm-lock.yaml`). `npx pnpm@10`
  re-downloads and hangs in the foreman environment; run the binaries in
  `Web/terminal/node_modules/.bin` instead.
- `swift test` runs on macOS only. Seven test files use `Bundle(for:)`,
  which corelibs-XCTest lacks. Linux CI runs `swift build` only.
- `KittermBench` `TUI-redraw` is flaky when it races shell startup. Re-run
  it before you treat a low byte count as a regression.
- The linger clock reaps an idle shell, not a working session (ADR 0002). A
  crew session with `claude` in the foreground is held past every window. A
  forgotten session stays until a foreman ends it.
