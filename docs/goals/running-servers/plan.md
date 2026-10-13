# Plan

The initial floor and the expected capability order for the goal in
`goal.md`. A human owns this file. A foreman proposes a change to it in a
round record; it does not edit it.

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Linux build | the `facts.md` docker pipe with `swift build --build-tests`; the PR's `linux-build` check proves it | `Build complete` |
| Swift tests | `swift test`, once by the crew; the PR's `test` check proves it again | exit 0 |
| Web | `Web/terminal`: `tsc --noEmit`, `vite build --outDir <scratch>`, `vitest run` | exit 0 |

A round that changes the page ships the proofs of `design/foundation.md`.
Each round adds at least one deterministic check. A check that exists is
frozen (see `LOOP.md`).

## Capability order

3 capabilities, one branch `goal/running-servers`, one pull request.

| # | Capability | Proof |
|---|---|---|
| 1 | **The route.** `GET /api/servers`: the listening TCP sockets of the user's processes from libproc (`proc_listpids`, `proc_pidinfo`, `proc_pidfdinfo` with `PROC_PIDFDSOCKETINFO`), the program by the `foregroundProgram` naming rule, the project by the session cwd rule, who started it by the controlling tty against each session's PTY, else the parent chain to a session's shell pid (bounded), else the top launcher below launchd; the HTTP probe (one request to `127.0.0.1:<port>`, a timeout under one second, cached per pid and port); on its own queue, cached a few seconds; full grade only; an empty list with a reason on Linux. | Swift tests with a scratch daemon: a listener in a pane, a detached one, one outside kitterm, an HTTP and a non-HTTP listener. |
| 2 | **The design.** A browser draft from the real list, then the approved draft as `Sessions 1200`, `Sessions 390` and a `Servers` part of `Sessions components` in `design/sessions.pen`, edited headless: the line shape, the link, the fold, the empty sentence. | The human approves; the foreman writes `corpus/01-approved-design.md` with the commit. |
| 3 | **The section.** The page draws SERVERS as the approved frames show, polls the route, keeps the fold in memory, hides it on a watch page, and prints the empty sentence. | Vitests on the pure model; the foundation's proofs; a screenshot against the live list. |

Capability 1 does not depend on the design, and runs while the human
chooses the draft. Capability 3 depends on 1 and 2.
