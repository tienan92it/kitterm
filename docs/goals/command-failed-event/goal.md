# Goal: the event feed says when a crew's command fails

## Objective

Today it does not. A command that ends with a non-zero exit in a crew
session changes the session row (`lastExit`, `mergedState: failed`), and
`PushNotifier` hears it through `SessionRegistryObserver.commandEnded`,
but `GET /api/events` carries no event for it. A foreman that holds one
`wait_for_events` for the whole daemon therefore learns of a failed
floor check, a crashed build or a dead test run only when it polls the
rows. `agent-push` round 3 found the gap and left it outside its
authority.

After this goal, a command that ends with a non-zero exit in an
orchestrated session appends one `command.failed` event to the feed. A
foreman's parked wait wakes on it, and the event names the session, the
command's index on `/commands`, and the exit code.

## Exclusions

- Orchestrated sessions only: a labelled or API-spawned session. A
  browser tab's shell fails commands all day, and the feed is a
  control-plane channel.
- No change to an existing event type, to `mergedState`, or to
  `PushNotifier`.
- No new exposure: the event carries the command line only as
  `GET /api/sessions/<id>/commands` already shows it, at the same grade.
- No event for a successful command. A foreman that needs every exit
  reads `/commands` or waits on a command.

## Completion condition

All five hold on a build from `main`:

1. A command that exits non-zero in an orchestrated session appends
   `command.failed` with `session`, `index` (the index
   `GET /api/sessions/<id>/commands` gives it), `exit`, and `command`
   when the row has one; a test drives a real shell and reads the feed.
2. A command that exits 0, and a command that fails in a browser
   session, append nothing; tests pin both.
3. A parked `GET /api/events` wakes on the event within the same poll,
   and `wait_for_events` in the MCP bridge names the type in its
   description.
4. `AGENTS.md` lists the type with the v1 event types, and the foreman
   skill's "Monitor" section says what to do on it.
5. `swift run KittermBench interactive-echo` stays under 50 ms p95; the
   append runs off the output path.

The floor (`swift test`, the Linux docker pipe, the bench) is green at
every step.
