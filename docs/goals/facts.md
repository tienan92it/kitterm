# Facts

Repository facts that a later round must not rediscover: measured
behaviour of the toolchain, the daemon, the pane, and the loop. One
bullet per fact, newest first inside its topic, each with its date and
source in parentheses. A goal-local finding stays in that goal's round
record. A foreman appends; the human prunes at every direction check. A
fact that becomes a rule moves to `LOOP.md`; one that becomes a design
decision moves to `docs/adr/`.

## Toolchain

- colima's sshfs mount can be dead while the VM is up, so a docker run
  with `-v $PWD:/src` sees an empty directory and the build silently
  tests nothing. Pipe a tar of `HEAD` into the container instead:
  `git archive HEAD | docker run -i ... `. Seen in three rounds across
  two goals on 2026-09-10, so assume it rather than test for it; a colima
  restart is the real fix and is the human's to make.
  (2026-09-10, `daemon-last-words` rounds 1 and 2, `foreman-harness`
  round 2)
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

- `--lan` with no `--trusted-host` grants unauthenticated full access to
  anything that reaches the daemon through a loopback proxy. In
  `AccessPolicy.decide`, an empty `trustedHosts` makes `viaTrustedHost`
  false, the proxy's peer is loopback, and `lanEnabled` skips the
  rejection check, so the branch returns `.allow(.full)`. Behind
  `tailscale serve` that is the whole tailnet, and it defeats the token
  grades and `--agent-control`. Measured: `200` full with `--lan` alone,
  `403 non-loopback Host` with neither flag, `403 missing or invalid
  token` with `--trusted-host` either way. Always pass `--trusted-host`
  behind a proxy. (2026-09-11, `agent-push` round 1)
- `tailscale cert` on macOS runs sandboxed. It writes only inside
  `~/Library/Containers/io.tailscale.ipn.macos/Data` and cannot write an
  absolute path, so every renewal for the daemon's own TLS listener is a
  copy, a `chmod 600` and a restart. `tailscale serve` avoids this
  because `tailscaled` keeps the key. (2026-09-11, `agent-push` round 1)
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

- A crew that runs `kitterm serve` must still set `KITTERM_STATE_DIR`
  **and** a free port, but a mistake no longer costs the live daemon its
  pid file. `serve` used to write the pid and the port before it bound, so
  a second daemon aimed at `~/.kitterm` clobbered the live daemon's pid
  even when its own bind then failed; `livePid()` read that dead pid,
  deleted the file, and reported "kitterm not running" while the daemon
  served on. That happened three times on 2026-09-10 and the foreman
  repaired the file by hand each time. Fixed on 2026-09-11 in `5c92731`
  (#96): `runDaemon` takes an `onListening` hook and `serve` writes both
  files from it, after the bind. `PidAfterBindTests` pins it with two real
  processes. A losing `serve` now writes nothing and logs `Address already
  in use (errno: 48)`. (2026-09-11, `fix/pid-after-bind`)
- A `serve` that loses the bind still writes one misleading line into the
  state directory's `server.log` first: the previous-run reader runs
  before the bind, so it reports the **live** daemon as a run that "ended
  with no recorded reason". It is only a log line and nothing else acts on
  it, but it is in the file a human reads to diagnose a restart.
  (2026-09-11, `fix/pid-after-bind`)
- An escape byte does not survive an MCP client's JSON string argument,
  and kitterm is not the layer that loses it. Measured 2026-09-10 by
  driving `kitterm mcp` with a hand-written JSON-RPC line into a pane
  running `xxd`: `text` spelled as a JSON escape arrives whole
  (`1b 5b 42`), a raw escape byte makes `JSONSerialization` reject the
  line so the call vanishes with no reply, and a doubly escaped spelling
  types six literal bytes. A client that strips control characters is
  what turns the Down arrow into two ordinary characters. Since round 1
  of `foreman-harness`, `send_input` takes `keys` (`up`, `down`, `left`,
  `right`, `enter`, `escape`, `ctrl-c`); use it for any key, and never
  try to carry a control byte in `text`. This corrects the entry written
  on 2026-09-09, which blamed the bridge.
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

- A test that builds its fixtures from the current clock proves only what
  is true today. Round 3 shipped a restart line that printed a bare
  "10:35 PM", with a green suite and a real `kill -9` behind it, because
  every test and every screenshot ran on the day the code was written. A
  stamp that can be old carries its date: `archivedFold` already did
  this, and `restartNotice` now does. Drive such a function with a fixed
  reference time, and test the midnight case in both directions.
  (2026-09-11, `daemon-last-words` round 4)
- The two muted text steps cannot carry the pages to 4.5:1 on their own.
  The surfaces are lifted from `--ui-bg` toward `--ui-lift`, so on a theme
  whose foreground sits near the floor, no colour dimmer than the
  foreground clears a lifted surface. Proved by setting both
  `--ui-text-muted` and `--ui-text-faint` to `--ui-text` itself: 32
  pair-and-theme cases still fail. The lever is the surface elevation.
  (2026-09-10, `contrast-tokens` round 2)
- `--ui-text-muted` is 82% of `--ui-text` and `--ui-text-faint` is 72%,
  both mixed toward `--ui-bg`. These are a floor, not a preference: a
  dimmer step drops pairs under 4.5:1 on `solarized-dark`, `synthwave-84`
  and `one-dark`. A brighter step passes more pairs but puts muted above
  body text in rank, which was built, photographed and rejected.
  (2026-09-10, `contrast-tokens` round 2)
- A `.css?raw` import returns an empty string under vitest, because
  vitest's css-disable plugin empties any id that holds `.css?`. A test
  that must read a stylesheet reads it with `node:fs` at test time
  instead. (2026-09-10, `contrast-tokens` round 1)
- The two pages use 45 distinct text-and-background pairs over 150 text
  rules, and 39 of the 45 miss 4.5:1 on at least one bundled theme. All
  17 bundled themes are dark. No text is large by the WCAG definition:
  the largest is the 20 px h1 at weight 600, under the 18.66 px bold
  threshold, so every pair takes 4.5:1 and none takes 3:1.
  (2026-09-10, `contrast-tokens` round 1)
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

- A round whose job is to move a value until a number passes must first
  set that value to its extreme and count what still fails. Two rounds in
  a row ended by proving their own lever insufficient, and both proved it
  that way in minutes. A recommendation that names a lever should carry
  the number the lever reaches, before the human spends a budget on it.
  (2026-09-11, `contrast-tokens` round 3)
- A round can be recorded as done and then fail review. The loop closes a
  round on a green floor and a clean diff; the human's rule puts the
  review before the merge, which is after the round closes. On 2026-09-10
  round 4 of `foreman-harness` was written up as complete, and two
  reviewers then found four defects in it. Do not treat a round record as
  final until the review returns. (2026-09-10, `foreman-harness` round 5)
- Two blind reviewers are worth their cost on a document change. Both
  found the same hole in a substring check and described it the same way:
  a file can carry the exact marker while stating the rule backwards. One
  wrote the inverted sentence out, the crew used it as an acceptance test,
  and the foreman ran it again against the finished file.
  (2026-09-10, `foreman-harness` round 5)
- A round that needs a change under a path it may not write delivers a
  command, not a description. On 2026-09-10 a crew wrote the patch for
  `docs/goals/LOOP.md` as one `git show ... | sed ... | git apply -C1
  --recount -` line, proved it by running it against a copy in a scratch
  tree and diffing byte for byte, and said plainly it had not run the
  suite green. The foreman ran that one command and the floor went green
  on the first try. (2026-09-10, `foreman-harness` round 4)
- A capability whose deliverable spans the crew's files and a
  foreman-owned file is red at the crew's last commit by construction,
  and the round is not failed. Expect the handoff and read the red floor
  as the handoff. (2026-09-10, `foreman-harness` round 4)
- Before starting a round, read the other open rounds' plan rows and name
  the shared file in the prompt. On 2026-09-10 the foreman gave
  `daemon-last-words` and `contrast-tokens` the same
  `Web/terminal/src/theme-contrast.test.ts` in the same hour. The queue is
  scheduled by the `Updated` date, not by the files a capability names, so
  nothing in the loop catches the collision. The second crew found it
  itself and said so in its first note. (2026-09-10, `daemon-last-words`
  round 3)
- After a round's floor, either send the prompt or record why not. On
  2026-09-10 the foreman spawned a pane, ran its floor, turned to another
  goal, and left it idle for twenty minutes with no task. The loop says
  to commit to the base before the prompt; it never said to send the
  prompt, because that was assumed. (2026-09-10, `foreman-harness`
  round 3)
- `post_note` caps a note at 2048 bytes and cuts what is over rather than
  refusing it, so a crew that reads its own note back sees the truncation
  and posts again. Ask for a note under the cap and say what the cap
  does. (2026-09-10, `daemon-last-words` round 1)
- One crew, one worktree. Two crews in one checkout cut branches from
  whatever `HEAD` happens to be and rebase over each other; on
  2026-09-10 that put one round's commit under another's branch and cost
  a rescue, though nothing was lost. (2026-09-10)
- Never move `HEAD` in a checkout a crew is using. On 2026-09-10 the
  foreman ran a verification build on one crew's branch in the shared
  checkout while a second crew was live; the second crew had made its own
  worktree and lost nothing, but it had cut its branch while `HEAD` sat
  on the first crew's, so its base carried the other round's commit.
  Verify a branch in a worktree of your own, or wait until the crew ends.
- A crew that spawns its own helper session copies the round's four
  labels onto it, so a scan by label counts the helper as a round
  session. Track the id you spawned when you watch a round.
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
