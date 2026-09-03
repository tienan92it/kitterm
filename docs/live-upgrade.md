# Live upgrade: exec takeover

| | |
|---|---|
| Status | Proposed |
| Issue | [#47](https://github.com/tienan92it/kitterm/issues/47) |
| Builds on | #46 (`upgrade --restart`), #31 (`KITTERM_STATE_DIR`) |
| Date | 2026-09-03 |

## Objective

`kitterm upgrade --live` replaces the running daemon with the new binary, and no shell, agent, or scrollback is lost.

## Background

`scripts/install.sh` already swaps `$PREFIX/lib/kitterm` in place while the daemon runs from the unlinked inode. `BuildVersion.running` is frozen at boot; `BuildVersion.onDisk()` re-reads `share/kitterm/VERSION`. The pair detects a pending update (`InstallLayout.swift:5-11`).

#46 added `upgrade --restart`: one `launchctl kickstart -k` order that survives the caller's death. But the daemon owns every PTY master (`PtySession.masterFD`). Daemon exit closes the masters, so every shell and every agent dies. That is the remaining half of "upgrade without interruption".

The issue #47 sketch is close, but four of its premises do not match the code. This doc corrects them:

1. NIO does not own the master fd. `PtySession` keeps `masterFD` and gives NIO a `dup()` (`PtySession.swift:332`). Closing the channel does not close the master. The real hazard is the opposite one: `masterFD` carries `FD_CLOEXEC` (`PtySession.swift:196`) and would die at `exec`.
2. `PtySession` holds no title and no histKey. The client builds the title; `histKey` is per-connection state on `WebSocketSessionHandler`. Neither needs to cross the boundary.
3. No linger timestamps exist. `SessionRegistry.lingerTasks` holds live `Task`s only. There is nothing to carry, so the successor restarts the windows.
4. Retained logs are not append-only. `SessionLogStore.rotate` truncates and rewrites, and its `origin`/`fileBase`/`streamEnd` live only in memory. A path alone is not enough to reopen one.

## Goals

- No shell or agent process restarts during an upgrade.
- Client replay stays exact: after reconnect, `?since=<offset>` returns the gap bytes, never the resync path.
- The visible client gap stays under one second.
- Every failure degrades to today's `upgrade --restart` outcome or better. A dead daemon is never an outcome.
- The handoff format survives version skew: the old binary writes it, the new binary reads it.

## Non-Goals

- Zero listen gap. A few milliseconds of refused connections are accepted; clients already retry.
- Carrying live WebSocket connections, controller roles, or observers. Every socket dies; clients reconnect and roles resolve fresh.
- Carrying approval holds. They expire with the standard no-decision answer (`ApprovalStore.expire`), and the agent asks again in its pane.
- Downgrade across a format break. The reader must be the same version or newer.

## Design overview

The daemon execs the staged binary in place. Same PID, same launchd job, same children. Only the PTY masters and the session state cross the boundary; everything socket-shaped is rebuilt.

![Takeover sequence](diagrams/live-upgrade-takeover.svg)

Source: `diagrams/live-upgrade-takeover.sequence.json` (archify). See
[architecture.md](architecture.md) for the steady-state system.

## Trigger and validation

`kitterm upgrade --live` stages via `install.sh` with `KITTERM_DEFER_RESTART=1`, exactly as `--restart` does. It then calls a new endpoint, `POST /api/upgrade/takeover` (loopback + token, like every `HTTPAPIHandler` route).

The CLI refuses without the login agent, the same rule as `takeOverNow()` in #46. `launchd` `KeepAlive` is the recovery net if the successor crashes after `exec`; without it, a crash strands the daemon down.

The daemon validates before it commits: it runs `<prefix>/lib/kitterm/kitterm --help` and refuses a takeover into a binary that cannot run. The installer's own smoke test (`install.sh:86`) runs pre-install and does not cover a binary damaged after install. The endpoint replies `200` before quiesce starts, so a caller inside a pane gets its answer.

## Quiesce

All teardown runs on the single event loop (`DaemonServer` uses one thread), so no reader races it.

1. Refuse new sessions and new connections.
2. Call `flushNow()` on every `OutputBatcher`, then close it. `close()` alone discards its buffer (`OutputBatcher.swift:56-62`).
3. Close both listeners and every WebSocket; wait for the close futures.
4. Close each session's read channel. This closes NIO's dup, not the master.
5. Drain the recorder and log-store dispatch queues with `queue.sync {}`. `exec` destroys threads, and an async write still in a queue is lost.
6. Shut down the event loop group.

Do not pause reading first: `handleRead` drops bytes while paused (`PtySession.swift:389`). Bytes not yet read stay in the kernel PTY buffer, survive `exec`, and the successor reads them. That property is what makes the handoff lossless without any read-side draining.

## The fd handover

Per session, clear `FD_CLOEXEC` on `masterFD` just before `exec`; the successor sets it again after adoption. `O_NONBLOCK` lives on the open file description and survives `exec` untouched.

Two fds must *not* leak into the successor:

- NIO's dup of the master: POSIX `dup()` clears `FD_CLOEXEC`, so the dup only dies at `exec` if its channel is fully closed first. The close-future wait in quiesce guarantees that.
- The listening sockets: closed in quiesce; the successor re-binds.

## The handoff state

The old binary writes a directory under the state dir (`DaemonPaths`, so `KITTERM_STATE_DIR` keeps working): `takeover/state.json` plus `takeover/rings/<sessionID>.bin`. Then it calls `execv` on `<prefix>/lib/kitterm/kitterm` with `serve --takeover <dir>` and the original serve flags.

`state.json` starts with `"formatVersion": 1`. Per session it records:

| Field | Source | Why |
|---|---|---|
| `fd` | duplicated master fd number | the session itself |
| `sessionID`, `pid`, `shellPath`, `initialCwd`, `profileName`, `labels` | `PtySession` immutables | identity and reattach routing |
| `cols`, `rows`, `lastPolledCwd`, `submittedCommand` | `PtySession` mutables | client meta on reattach |
| `terminated`, `shellExitCode`, `exitNotified` | exit state | a lingering exited session stays reportable |
| `detachOffset`, `log.head`, ring bytes (side file) | `SessionLog` | exact `?since` replay across the boundary |
| marks | `SessionMarkStore` | jump-to-mark survives |
| `recorder.path`, `recorder.startedAt` | `SessionRecorder` | cast timestamps keep their origin |
| `logStore.path`, `logStore.fileBase`, `logStore.streamEnd` | `SessionLogStore` | offset translation is memory-only today |

Not carried, by decision: titles and histKeys (client- and connection-side), observers and controllers (dead sockets), `commandWaiters` (promises die with connections), approval holds (expired), linger timestamps (none exist; windows restart, which only extends them).

Size bound: rings are ≤ 4 MiB per session (`Constants.sessionLogBytes`) and sessions cap at 64, so ≤ 256 MiB worst case. Typical is a few MiB; the write fits inside the one-second budget.

Compatibility rule: the *old* binary writes, the *new* one reads. The reader ignores unknown fields. This is the first versioned state format in the project; it must hold from every release to the next.

## Failure ladder

Each rung lands on today's behaviour or better. The order below is the order the risks occur.

1. Validation fails → refuse the endpoint call. Nothing changed.
2. `execv` returns an error → the old process is still alive and still holds every fd. It re-runs its own rehydrate path from the state it just wrote and continues on the old version.
3. The successor cannot read the state (version skew, corrupt file) → it closes the inherited fds and boots clean. Children hang up; this equals `upgrade --restart`.
4. The successor crashes during rehydrate → launchd (`KeepAlive true`) restarts it clean. Same outcome as rung 3.

## Rehydrate

`serve --takeover <dir>` runs before the normal boot path:

1. Read `state.json`; refuse an unknown major version (rung 3 above).
2. Rebuild each `PtySession` around its inherited fd: a new adopting initializer that skips `openpty` + spawn, sets `FD_CLOEXEC`, and restores the fields above.
3. Restore each `SessionLog` ring and `head`, so `snapshot(from:)` answers exactly for pre-takeover offsets.
4. Restart the exit watchers. `exec` keeps the PID, so the daemon is still the parent and `waitpid` works. A child that exited mid-takeover is a zombie the new watcher reaps at once.
5. Reopen the recorder in append mode with the carried `startedAt`; reopen the log store with the carried `fileBase`/`streamEnd`.
6. Register every session as detached; linger windows start fresh.
7. Delete the takeover directory, re-bind the listeners, rewrite `pid`/`port`, and serve.

Clients reconnect exactly as after any transient disconnect. The ring came across, so `sinceOffset` hits the exact-gap path and the `logState` resync bit stays 0.

## Alternatives considered

**Parallel successor with `SCM_RIGHTS` fd passing.** A second daemon receives the fds over a Unix socket, then the old one exits. This closes the listen gap but doubles the live states: two daemons, one port, and a fight with launchd's one-process job model. Rejected; the gap it removes is milliseconds that clients already tolerate.

**Drop the rings, keep only metadata.** The state shrinks to kilobytes, but every reconnect takes the pruned path: a resync and a 128 KiB tail (`PtySession.swift:736-753`). Scrollback visibly breaks on every upgrade. Rejected; 256 MiB worst case is cheap and transient.

**Carry approval holds.** Their own semantics argue against it: `expire` already answers `nil`, and the agent falls back to its own pane (`ApprovalStore.swift:20-23`). Carrying them adds promise re-plumbing for a five-minute-max hold. Rejected.

**Stay with #46.** Zero new code, but agents keep dying on upgrade, which is the point of the issue. Rejected.

## Testing

- Unit: state round-trip; unknown-field tolerance; unknown-version refusal; ring restore makes `snapshot(from:)` exact.
- Integration: a scratch daemon under `KITTERM_STATE_DIR` runs a counter loop in a session, execs itself, and the test asserts the same PID, an unbroken byte stream, and a live child.
- Regression gates: `swift test` and `KittermBench` stay green; the takeover code adds nothing to the steady-state event loop or per-connection path.

## Open issues

**NIO socket `FD_CLOEXEC`.** Whether NIO marks its listener and accepted sockets close-on-exec is unverified. If it does not, an unclosed straggler leaks into the successor and can hold the port. Candidate answers: rely on the quiesce close-future wait, or add a close-everything-above-stderr sweep before `exec`, exempting the carried fds. Next step: read `NIOBSDSocket` creation paths in swift-nio 2.101.3.

**`OscMarkScanner` mid-sequence state.** The scanner is a streaming parser; at takeover it can sit mid-escape-sequence. Not carrying it can lose one mark that straddles the boundary. Candidate answers: accept the loss, or flush the scanner at quiesce. Next step: measure whether a lost boundary mark is observable in practice; decide, then close.

**Linux without a supervisor.** `exec` itself is portable, but the crash net (rung 4) is launchd-specific. The CLI refuses `--live` without the login agent, which excludes Linux for now. Next step: a follow-up issue for a systemd-unit equivalent once anyone runs kitterm under systemd.
