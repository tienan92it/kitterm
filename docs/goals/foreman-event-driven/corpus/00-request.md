# The human's word: a normal foreman, not a poll loop

2026-10-30, in the foreman's pane. The human found the foreman's
monitoring annoying — one 45-minute turn, 55+ `wait_for_events` polls,
85k tokens, waking on every project's events. The workflow the human
wants:

> - Foreman plan and delegate the work. Spawn crews for tasks. Report to
>   me after crew complete their pieces of work.
> - Crew handle the dedicated tasks, report to foreman when it done.
> Loop and polling look annoying.

The first attempt (PR #207, a chore) hit a frozen test that bans `curl`
in the skill. Shown three options, the human chose:

> go with option 1

Option 1: add a first-class CLI primitive so the skill names a kitterm
command, not `curl`. The command does the background event-wait that
re-invokes the idle foreman.

The rules:

1. **`kitterm foreman watch`** blocks on `GET /api/events` and exits on
   the first event that concerns a named crew session — a `note`, an
   `agent.status` of `needs-input`/`completed`/`failed`, an
   `approval.pending`, a `command.failed`, or a `session.exited`/
   `removed` — printing that event so the foreman reads what happened.
2. It also exits on a **heartbeat** (so a stall check still runs) and on
   a **daemon epoch change** (so a restart is seen), and carries the
   feed cursor in (`--since`, `--epoch`) and prints the next cursor out,
   so no event between two runs is missed.
3. It takes one or more `--session <id>` (and may take `--scope`/
   `--project` later); with none it is a usage error, because a watch
   over everything is the loop this goal removes.
4. **No `curl`, no new daemon route.** It is a Swift HTTP client of the
   existing feed, beside `kitterm foreman catch-up`.
5. The **skill** then delegates, reports, runs this command in the
   background, and ends its turn; a wake makes it act and report after
   each crew completes, then delegate the next or stop.
