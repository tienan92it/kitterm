# Live upgrade: exec takeover

| | |
|---|---|
| Status | Accepted |
| Issue | [#47](https://github.com/tienan92it/kitterm/issues/47) |
| Builds on | #46 (`upgrade --restart`), #31 (`KITTERM_STATE_DIR`), #57 (event-feed epoch) |
| Date | 2026-09-07 |

## Objective

`kitterm upgrade --live` replaces the running daemon with the new binary, and no shell, agent, or scrollback is lost.

## Background

`scripts/install.sh` swaps `$PREFIX/lib/kitterm` in place while the daemon runs from the unlinked inode. `BuildVersion.running` is frozen at boot; `BuildVersion.onDisk()` re-reads `share/kitterm/VERSION`. The pair detects a pending update.

#46 added `upgrade --restart`: one `launchctl kickstart -k` order that survives the caller's death. But the daemon owns every PTY master (`PtySession.masterFD`). Daemon exit closes the masters, so every shell and every agent dies. Seven upgrades in four days each dropped every pane and killed the `claude` processes inside them.

Four premises of the issue #47 sketch did not match the code. The design corrects them:

1. NIO does not own the master fd. `PtySession` keeps `masterFD` and gives NIO a `dup()`. Closing the channel does not close the master. The real hazard is the opposite one: `masterFD` carries `FD_CLOEXEC` and would die at `exec`.
2. `PtySession` holds no title and no histKey. The client builds the title; `histKey` is per-connection state on `WebSocketSessionHandler`. Neither crosses the boundary.
3. The registry holds live linger `Task`s, which cannot cross. The successor restarts the windows. Since #61 the registry also holds `heldSince` per session, a timestamp, which does cross.
4. Retained logs are not append-only. `SessionLogStore.rotate` truncates and rewrites, and its `fileBase` and `streamEnd` live only in memory. The state file carries them.

## Goals

- No shell or agent process restarts during an upgrade.
- Client replay stays exact: after reconnect, `?since=<offset>` returns the gap bytes, never the resync path.
- The visible client gap stays under one second.
- Every failure degrades to today's `upgrade --restart` outcome or better. A dead daemon is never an outcome.
- The handoff format survives version skew: the old binary writes it, the new binary reads it.

## Non-Goals

- Zero listen gap. A few milliseconds of refused connections are accepted; clients already retry.
- Carrying live WebSocket connections, controller roles, or observers. Every socket dies; clients reconnect and roles resolve fresh.
- Carrying approval holds. The hook's HTTP connection closes with the old process, and the agent asks again in its pane.
- Carrying input in flight. A paced body (`send_input` into a program, #65) that is mid-way at the takeover is cut at the piece that was written last. The caller gets a connection error and reads the screen before it types again.
- Downgrade across a format break. The reader must be the same version or newer.

## Design overview

The daemon execs the staged binary in place. Same PID, same launchd job, same children. Only the PTY masters and the session state cross the boundary; everything socket-shaped is rebuilt.

![Takeover sequence](diagrams/live-upgrade-takeover.svg)

Source: `diagrams/live-upgrade-takeover.sequence.json` (archify). See
[architecture.md](architecture.md) for the steady-state system.

The code sits in four places:

| Piece | File | Role |
|---|---|---|
| State format | `TakeoverState.swift` | `formatVersion: 1`, the fields below, load with version refusal |
| Process half | `TakeoverHandoff.swift` | target binary, `--help` check, fd sweep, `execv`, successor argv |
| Quiesce and adopt | `DaemonServer.swift` | `prepareHandoff`, `init(adopting:)`, `init(carrying:)`, the `runDaemon` loop |
| Route | `HTTPAPIHandler.swift` | `POST /api/upgrade/takeover` through `TakeoverController` |

## Trigger and validation

`kitterm upgrade --live` stages the release through `install.sh` with `KITTERM_DEFER_RESTART=1`, exactly as `--restart` does. It then calls `POST /api/upgrade/takeover` and polls `/api/version` until `running` equals the staged version.

The CLI refuses `--live` without the login agent, the same rule as `--restart`. `launchd` `KeepAlive` is the recovery net if the successor crashes after `exec`; without it, a crash strands the daemon down. The CLI refuses `--live` on Linux for the same reason: no supervisor exists there yet.

The route admits a caller on loopback with full grade, and nobody else: it makes this process exec a binary as the user. It has no body. The daemon execs `<prefix>/lib/kitterm/kitterm` when it runs from an install, which is where the installer staged the new build, else its own executable (a build tree, or the integration test).

The daemon validates before it commits: `TakeoverHandoff.validate` runs the target with `--help` off the event loop and refuses a binary that cannot run (`422`). A second request while one is admitted answers `409`. A handler with no server behind it answers `503`. The route answers `200 {ok, pid, executable, running, installed}` before quiesce starts, so a caller inside a pane reads its answer.

## Quiesce

The route only records the request and closes the listeners. That wakes the main thread out of `DaemonServer.waitUntilClosed()`, which returns `.takeover`, and `runDaemon` calls `prepareHandoff`. Every teardown step below is submitted to the single event loop or waits on it, so no reader races it.

1. Close both listeners and wait. Nothing new arrives.
2. Flush every WebSocket's `OutputBatcher` (`WebSocketSessionHandler.flushOutput`), then close every accepted connection and wait for the close futures. `ConnectionTracker` holds the list; NIO keeps none.
3. Close each session's read channel (`PtySession.releaseReader`) and wait. This closes NIO's dup, not the master. The ring and the marks are final from here.
4. Snapshot each session (`PtySession.handoffState`). The snapshot drains the recorder and the log-store queues with `queue.sync {}`: `exec` destroys threads, and an async write still in a queue is lost.
5. Write the state directory.
6. Shut down the event loop group.

Reading is never paused: `handleRead` drops bytes while paused. Bytes the shell writes after step 3 wait in the kernel PTY buffer, survive `exec`, and the successor's reader takes them. That property is what makes the handoff lossless with no read-side drain.

## The fd handover

Just before `exec`, `TakeoverHandoff.prepareDescriptors` walks every fd above stderr. It clears `FD_CLOEXEC` on the carried masters and sets it on everything else. The successor sets it again on each master when it adopts it. `O_NONBLOCK` lives on the open file description and survives `exec` untouched.

The sweep exists because swift-nio sets no close-on-exec on the sockets it opens on Darwin (`BaseSocket.makeSocket` sets non-blocking only). A listener or an accepted socket that quiesce did not fully close would follow the process into its next image and could hold the port. The sweep makes the quiesce wait a courtesy, not a correctness property.

Two fds must not leak into the successor:

- NIO's dup of the master: closed in step 3, and swept if the close had not landed.
- The listening sockets: closed in step 1, and swept.

## The handoff state

The old binary writes `~/.kitterm/takeover/` under the state directory (`DaemonPaths.takeoverDirectory`, so `KITTERM_STATE_DIR` keeps working): `state.json` plus `rings/<sessionID>.bin`. Then it calls `execv` on the target with the original `serve` argv plus `--takeover <dir>` (any earlier `--takeover` pair is dropped first, so a takeover of a takeover carries no stale directory).

`state.json` starts with `"formatVersion": 1`. The top level records:

| Field | Why |
|---|---|
| `writtenBy` | the writer's version, for the log line |
| `fds` | the carried fd numbers, so a reader that refuses the rest can still close them |
| `eventLog.epoch`, `eventLog.lastSeq`, `eventLog.events` | the feed continues, so a foreman's cursor stays valid (#57) |

Per session it records:

| Field | Source | Why |
|---|---|---|
| `fd` | `masterFD`, absent for an exited session | the session itself |
| `sessionID`, `pid`, `shellPath`, `initialCwd`, `profileName`, `labels`, `spawnedByAPI` | `PtySession` immutables | identity, reattach routing, linger class |
| `name`, `note` | `PtySession` metadata | the fleet row and the tab title |
| `cols`, `rows`, `lastPolledCwd`, `submittedCommand` | `PtySession` mutables | client meta on reattach; the next command's name |
| `terminated`, `shellExitCode`, `exitNotified` | exit state | a lingering exited session stays reportable |
| `detachOffset`, `logHead`, ring bytes (side file) | `SessionLog` | exact `?since` replay across the boundary |
| `marks`, `droppedCommands` | `SessionMarkStore` | jump-to-mark survives; command indexes keep their numbers |
| `lastOutputAt`, `agentStatus` | `PtySession` evidence | `mergedState` and the linger clock judge from the same facts |
| `recorder.path`, `recorder.startedAt` | `SessionRecorder` | cast timestamps keep their origin |
| `logStore.path`, `logStore.fileBase`, `logStore.streamEnd` | `SessionLogStore` | offset translation is memory-only today |
| `heldSince` | `SessionRegistry` | the hold a foreman compares against (#61) keeps its start |

Not carried, by decision: titles and histKeys (client- and connection-side), observers and controllers (dead sockets), `commandWaiters` and event waiters (promises die with connections), approval holds, linger tasks (windows restart), the `OscMarkScanner` mid-sequence state (one mark that straddles the boundary can be lost), and input in flight. `foregroundProgram` (#63) and `inputIsCanonical` (#66) are kernel reads made at request time, so nothing of theirs exists to carry.

Size bound: rings are at most 4 MiB per session (`Constants.sessionLogBytes`) and sessions cap at 64, so at most 256 MiB. Typical is a few MiB; the write fits inside the one-second budget.

Compatibility rule: the old binary writes, the new one reads. The reader ignores unknown fields (`Codable` does) and refuses a `formatVersion` it was not built for. This is the first versioned handoff format in the project; it must hold from every release to the next.

## Failure ladder

Each rung lands on today's behaviour or better. The order below is the order the risks occur.

1. Validation fails, or another takeover is in flight: the route refuses. Nothing changed.
2. `execv` returns an error: the old process is still alive and still holds every fd. `runDaemon` puts `FD_CLOEXEC` back on the masters, deletes the directory, builds `DaemonServer(config:carrying:)` over the same registry and feed, and serves on with the old code. Every session gets a fresh reader; the feed records a second `daemon.started` in the same epoch.
3. The successor cannot read the state: an unknown `formatVersion` or an unreadable file. It closes the fds the envelope lists and boots clean. Children hang up; this equals `upgrade --restart`.
4. The successor crashes during adoption: launchd (`KeepAlive true`) restarts it clean. Same outcome as rung 3.

## Rehydrate

`serve --takeover <dir>` runs `makeServer` before the normal boot path:

1. Read `state.json`; refuse an unknown `formatVersion` (rung 3).
2. Continue the feed: `EventLog(restoring:)` keeps the epoch and the ring, and `markStarted(takeover: true)` appends `daemon.started` with `takeover: "true"` inside it.
3. Rebuild each session around its inherited fd: `PtySession(adopting:ring:)` skips `openpty` and spawn, sets `FD_CLOEXEC`, restores the fields above, restores the ring with `SessionLog(restoring:head:)` so `snapshot(from:)` is exact for pre-takeover offsets, and starts the exit watcher. `exec` kept the PID, so the daemon is still the parent and `waitpid` works; a child that exited mid-takeover is a zombie the new watcher reaps at once. A session that arrives with no fd adopts as terminated with its records.
4. Reopen the recorder in append mode with the carried `startedAt`, and the log store with the carried `fileBase` and `streamEnd` (`PtySession.reattachFiles`).
5. In `start()`, before the listeners bind: `SessionRegistry.adopt` registers every session as detached with its `heldSince`, no `session.created` is emitted, exit reporting is wired as for an API-spawned session, and every session gets a reader on the loop.
6. Delete the takeover directory, bind the listeners, rewrite `pid` and `port`, and serve.

Clients reconnect exactly as after any transient disconnect. The ring came across, so `sinceOffset` hits the exact-gap path and the `logState` resync bit stays 0. A foreman's `wait_for_events` call fails once with a connection error; the same cursor and epoch then answer without `pruned`, and the first new event is `daemon.started` with `takeover` true.

## Alternatives considered

**Parallel successor with `SCM_RIGHTS` fd passing.** A second daemon receives the fds over a Unix socket, then the old one exits. This closes the listen gap but doubles the live states: two daemons, one port, and a fight with launchd's one-process job model. Rejected; the gap it removes is milliseconds that clients already tolerate.

**Drop the rings, keep only metadata.** The state shrinks to kilobytes, but every reconnect takes the pruned path: a resync and a 128 KiB tail. Scrollback visibly breaks on every upgrade. Rejected; 256 MiB worst case is cheap and transient.

**Carry approval holds.** Their own semantics argue against it: `expire` already answers `{}`, and the agent falls back to its own pane. Carrying them adds promise re-plumbing for a five-minute-max hold. Rejected.

**Rebuild new objects on a failed `exec`.** Rung 2 could adopt from the file it just wrote, as the successor does. That leaves the old `PtySession` objects alive in the same process with the same fds, and their `deinit` closes the fds and signals the shells. Rejected; the same objects serve on instead.

**Stay with #46.** Zero new code, but agents keep dying on upgrade, which is the point of the issue. Rejected.

## Testing

- `TakeoverStateTests`: state round trip through a directory with `0600`; unknown-field tolerance; unknown-version refusal that still yields the fds; ring restore keeps `snapshot(from:)` exact and continues the stream; a smaller ring keeps the tail; the feed restore continues the epoch; mark-index numbering continues; an exited session adopts with its records; successor argv; binary validation.
- `TakeoverResumeTests`: rung 2 in-process. A server spawns `cat`, `prepareHandoff` writes the state, and `DaemonServer(config:carrying:)` serves the same session on the same port with the same epoch.
- `LiveTakeoverTests`: the real `kitterm serve` binary under `KITTERM_STATE_DIR` with `cat` in the foreground of an API session. The test asserts the same daemon pid before and after, a live shell pid, `foregroundProgram` still `cat`, a client that reconnects with `?since=` and gets no resync, a stream assembled across the boundary that equals the ring byte for byte from offset zero, `daemon.started` with `takeover` true in the same epoch with an old cursor not pruned, and `409` for a second takeover.
- Regression gates: `swift test` and `KittermBench` unchanged; the takeover code adds one dictionary insert per accepted connection and nothing to the output path.

## Closed issues

**NIO socket `FD_CLOEXEC`.** Verified: swift-nio 2.101 does not set it on Darwin. The sweep before `exec` closes the question.

**`OscMarkScanner` mid-sequence state.** Not carried. A mark whose escape sequence straddles the boundary is lost; the next prompt's marks resume the index. Accepted: the loss is one mark per upgrade per session, and only when the shell is printing a mark at the instant of the handoff.

## Open issues

**Linux without a supervisor.** `exec` itself is portable, and the daemon side runs on Linux. The crash net (rung 4) is launchd-specific, so the CLI refuses `--live` there. Next step: a follow-up issue for a systemd-unit equivalent once anyone runs kitterm under systemd.
