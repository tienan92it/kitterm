# Facts

Repository facts that a later round must not rediscover: measured
behaviour of the toolchain, the daemon, the pane, and the loop. One
bullet per fact, newest first inside its topic, each with its date and
source in parentheses. A goal-local finding stays in that goal's round
record. A foreman appends; the human prunes at every direction check. A
fact that becomes a rule moves to `LOOP.md`; one that becomes a design
decision moves to `docs/adr/`.

## Toolchain

- This machine runs near its memory limit: on 2026-09-09 swap was
  7.66 GB of 8 GB used, with a docker VM the largest consumer. A Swift
  build spike is then enough for the kernel to kill the kitterm daemon
  silently, with no crash report, and its launchd `KeepAlive` agent
  restarts it with a new pid and a fresh epoch. Three restarts happened
  that afternoon; each one killed every session. Run one heavy build at a
  time, and commit a crew's work as it lands.
- A live check of the CLI runs `.build/debug/kitterm` (fresh after `swift
  test`), because `swift run` needs `Package.swift` in the cwd.
  `KITTERM_STATE_DIR` isolates the state. (2026-09-08, round 3)
- The Linux docker build re-points `.build/debug` at the Linux tree; the
  next `swift build` restores it. Run it alone, after `swift test`, never
  while a test run shares `.build`. (2026-09-08, rounds 6 and 7)
- The web package manager is pnpm. `npx pnpm@10` re-downloads and hangs;
  run `Web/terminal/node_modules/.bin/{tsc,vite,vitest}`. (2026-09-04)
- `swift test` runs on macOS only; seven test files use `Bundle(for:)`.
  Linux CI runs `swift build`. (2026-09-04)
- `KittermBench` `TUI-redraw` is flaky when it races shell startup;
  re-run before treating a low byte count as a regression. (2026-09-04)
- `Tests/KittermCLITests/MCPToolsTests.swift` pins the MCP tool count;
  every new tool changes that line. (2026-09-08, round 1)

## Daemon and API

- `PtySession.foregroundIsShell` is true in three cases, not one: the
  shell reads the terminal, nothing has claimed the tty yet, or the spawn
  helper holds it before it execs the shell. So it is a no-op as a "the
  shell is ready" gate, and `!foregroundIsShell` names any program rather
  than a chosen one. Wait for the program by name, or for
  `inputIsCanonical == false`, whichever the next lines need
  (`Tests/KittermDaemonTests/ForegroundWait.swift`). Measured 2026-09-10
  with a spawn-helper shim that slept 3 s.
- The kernel reports a shell's cwd as a real path, `/private/var/…` on
  macOS; Foundation's `resolvingSymlinksInPath()` keeps `/var/…`, so a
  registered root must go through `realpath(3)`. `Projects.canonicalRoot`
  does. (2026-09-08, round 1)
- `PtySession`'s cwd poll runs only while a controller is attached; a
  detached crew session needs a row-time check against the kernel cwd
  for any poll-driven field. (2026-09-08, round 1)
- A registered root that is a parent of a git checkout swallows that
  checkout's sessions: a registered prefix beats the git walk. A proposal
  to reverse the order is open. (2026-09-08, round 2)
- A hook can name a session id the daemon no longer has: a `claude`
  started before a daemon restart keeps the old `KITTERM_SESSION_ID`, and
  the fleet view then shows an approval with no pane. (2026-09-08)
- A `note` from `post_note` lives only in the 1024-event ring and is lost
  on restart; the round record is the durable copy. (2026-09-08)
- The linger clock reaps an idle shell, not a working session (ADR 0002);
  a forgotten crew session with `claude` in the foreground stays until a
  foreman ends it. (2026-09-04)
- Since v0.22.0 `kitterm upgrade --live` keeps sessions, ids, and the
  event `epoch`; verified again on 2026-09-08 with v0.23.0. (2026-09-07)

## Crew pane

- The MCP bridge's `send_input` drops the escape byte: a body that starts
  with the escape byte (0x1b) followed by `[B` arrives as the two bytes
  `[B`, so an arrow key never reaches the pane. Send a keystroke through
  the HTTP input route instead: `printf '\033[B' | curl --data-binary @-
  http://127.0.0.1:3418/api/sessions/<id>/input`. (2026-09-09, round 8)
- A `claude` pane's raw output is not a transcript: Claude Code redraws
  in fragments with cursor moves, so a search of the retained log or the
  output route for a phrase the pane showed finds nothing. Read a pane
  with `read_screen`; post what must be found later as a note.
  (2026-09-09, round 8)
- A fresh `claude` in a folder it has not seen shows the trust dialog
  even when the parent folder is trusted; answer it with one Down arrow
  and Enter in two calls, only when the cwd is a repository the human
  named. (2026-09-09, round 8)
- Since v0.21.1 the daemon types a body into a program in 512-byte pieces
  50 ms apart; before that Claude Code kept only the last read of a fast
  paste (59 of 2104 bytes on 2.1.260). A 64 KiB body takes about 6.5 s.
  Send one prompt in one call; never split it. (2026-09-07)
- Since v0.21.2 a body over 1024 bytes into a cooked reader answers 409;
  Darwin keeps 1024 bytes of a canonical line, Linux 4095. (2026-09-07)
- Since v0.20.0 `send_input` with `enter:true` presses Enter the way the
  reader expects, and `read_screen` marks dim runs `{dim}…{/dim}`; an
  empty Claude Code prompt shows a dim ghost suggestion. (2026-09-04)
- `claude --resume` needs the full transcript UUID; a prefix opens the
  picker, which finds nothing in a worktree cwd. (2026-09-07)

## Fleet view

- `sessions.ts` runs on import; page logic goes in a pure module with
  tests (`sessions-model.ts`, `approval-format.ts`). (2026-09-08)
- The page's own contrast pairs are pinned by `theme-contrast.test.ts`
  across every bundled theme; a new element adds its pair in the same
  round. `--ui-text-muted` is under 4.5:1 on 10 of 16 themes at the token
  level. (2026-09-08, rounds 5 and 7)
- A link that opens a served file must be checked on a browser that does
  not render the file's type: `text/markdown` with `nosniff` downloads on
  Chrome and Firefox; the routes serve `text/plain`. (2026-09-09, round 7)

## Foreman

- Never generate machine-wide load on the machine that hosts the crew.
  On 2026-09-09 a round ran `swift test` twenty times under eight `yes`
  processes; the load starved the daemon, its launchd `KeepAlive` agent
  restarted it with a new pid and a fresh epoch, and every crew session
  and its uncommitted work died. Reproduce a race by widening its window
  in a scratch copy of the test, which is deterministic, not by loading
  the machine, which is probabilistic and dangerous.
- Match a process by its executable, never by a bare string. Cleaning up
  that load with a `yes` pattern also matched `ssh -F ...` command lines
  and killed two of the human's `fly ssh console` connections. Use
  `pkill -x <name>` or match on `$11` of `ps` output, and list what will
  die before killing it.
- A foreman that runs as a background job wakes only when a background
  command exits. A one-shot shell loop that polls `GET /api/sessions`
  every 10 s, exits on a state change, and exits on its own after about
  560 s is the pattern that works; arm it against a state that already
  exists once before trusting it. An f-string with a backslash inside its
  expression silenced every earlier watcher. (2026-09-06)
- Commit to the base branch before sending a round's prompt; a crew
  branches off the base's HEAD when it starts. (2026-09-08, round 5)
- A review gate on `main...<top>` found one blocking and twenty-two
  should-fix items across four dimensions that five green floors did not;
  four reviewers plus one crew fit the three-session cap two at a time,
  the whole gate in 30 minutes. (2026-09-08, round 5)
- A review session that reads only through `git show <branch>:<path>`
  can share a checkout with a crew that edits another branch.
  (2026-09-08, round 4)
- Deleting a stacked PR's base branch closes the PR and GitHub refuses to
  reopen it until the branch exists again; retarget every remaining PR to
  `main` before the first `--delete-branch`. After `git merge origin/main
  -X ours` into a stacked branch, check `git diff <pre-merge> HEAD` is
  empty: the merge re-adds what the branch deleted. `gh pr edit` fails
  with a Projects (classic) error; `gh api -X PATCH … -F body=@file`
  works. (2026-09-08, merge of rounds 1 to 5)
- The installed `foreman-loop` skill ran three rounds on a fixture goal
  in 10 minutes 21 seconds with no human input and stopped at the budget
  with the digest shape from `LOOP.md`; it left the package uncommitted
  until told. (2026-09-09, round 8)
