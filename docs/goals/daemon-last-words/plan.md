# Plan

## The floor

The floor of `foreman-harness`, unchanged: `swift test`, KittermBench
`interactive-echo` p95 under 50 ms, `tsc` and `vite build` and `vitest`,
and the Linux build alone on a round that touches `Sources/`.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **A run records how it ended.** The daemon writes `~/.kitterm/last-run.json` (`{version, pid, startedAt, endedAt, reason, sessions}`) on a clean stop and on a takeover, with `reason` one of `stopped`, `restarted`, `takeover`. It writes the file's `startedAt`, `pid` and a periodic `sessions` count while it runs, so a killed run leaves a file with no `endedAt`. | Unit tests over the file's states; a test that a SIGTERM path writes `stopped`. |
| 2 | **The next start reads it.** On start the daemon logs one line: the previous run ended cleanly, or ended without a recorded reason at a given time holding N sessions. The same fact goes on the event feed as `daemon.started` data (`previous`: `clean` or `unrecorded`, with `pid`, `endedAt`, `sessions`). | A scratch daemon killed with `SIGKILL`, then started: the log line and the event carry `unrecorded`; after `kitterm stop`, they carry `clean`. |
| 3 | **The fleet view says it.** One line above the cards when the current run's `daemon.started` carries `previous: unrecorded`: the time and the session count, with a dismiss that keeps it dismissed for that run. Absent after a live upgrade. | Vitest over the model function; corpus request `01-unrecorded-restart` at 1200 px and 390 px. |

Capability 2 depends on 1; capability 3 depends on 2.
