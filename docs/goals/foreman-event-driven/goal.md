# Goal: the foreman delegates and yields, woken by its crews

The foreman must stop the in-turn `wait_for_events` poll loop. It plans,
delegates a round to a crew, reports, and ends its turn. A background
process wakes it only when one of its own crews posts a note, completes,
blocks, or exits. Then it verifies, reports to the human, and delegates
the next task or stops.

## Why this is a goal, not a chore

Round 9-era chore `foreman-event-driven` (PR #207, closed) hit a wall: a
background process that re-invokes an idle foreman learns of daemon
events only over HTTP, and `GoalsLayoutDocsTests` bans `curl` in the
skill. The human chose option 1: a first-class `kitterm foreman watch`
command the foreman runs in the background, so the skill names a kitterm
command, not `curl`. That is a CLI feature plus a skill rewrite — two
rounds.

## Completion

- `kitterm foreman watch` blocks on the daemon event feed and exits on
  the first event that concerns a named crew session (or a heartbeat, or
  a daemon epoch change), printing it, with no `curl`.
- The `foreman-loop` skill's `## Monitor` section uses it: delegate →
  report → yield → woken → act → report → next, scoped to the foreman's
  own crews.
- `swift test` green; `GoalsLayoutDocsTests` and the skill golden green.

## Exclusions

- No new daemon route (the event feed and its `session`/`since`/`epoch`
  query already exist). The command is a CLI client of the existing
  `GET /api/events`.
- No change to the crew note protocol, the stall rule, or the digest
  shapes.
