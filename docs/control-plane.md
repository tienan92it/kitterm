# kitterm control plane

This file holds the section `AGENTS.md` carried until 2026-11-10 (goal `lean-context`), moved here unchanged. A round that changes this surface updates this file.

## Control plane (`docs/goals/`)

- The repository is the control plane for agent work on it. `docs/goals/` holds the
  small package from "Building autonomous goal loops that deliver" (jx0.ca). Two files
  belong to the project: `LOOP.md` (procedure, authority tiers, budget, stop rules,
  round record shape) and `facts.md` (what a later round must not rediscover). Each
  goal is one folder, `docs/goals/<slug>/`: `goal.md` (objective, exclusions,
  completion condition), `plan.md` (the floor and the capability order), `STATE.md`,
  `corpus/` (approved requests), `rounds/` (one record per round). A goal's status is
  the `- Status:` line of its `STATE.md` (`active`, `waiting`, `stopped`, `done`); a
  goal never moves and there is no done folder
- Two files, two scopes. `facts.md` holds repository facts by topic, one dated bullet
  per fact with its source; only a repository fact goes there, and a goal-local finding
  stays in its round record; the human prunes it at every direction check. `STATE.md`
  is short: the `- Status:`, `- Round: N of M`, `- Rounds total:`, `- Last floor:`, and
  `- Updated:` lines, then `## Queue`, `## Failures`, `## Proposals waiting on the
  human`, `## Done`, and `## Next action`, and nothing else; narrative goes to
  `rounds/`. The card parses the status, round, and next-action lines, so their shape
  is an interface (`KnowledgeSummary`)
- Read `LOOP.md`, `facts.md`, and the goal's `goal.md` and `STATE.md` before you start a
  task here. Append a fact you had to measure to `facts.md`. Respect the authority tiers
  in `LOOP.md`: `goal.md`, `corpus/`, and an existing check are frozen inside a round;
  `plan.md`, `LOOP.md`, and `docs/adr/` take a proposal in the round record, not an edit
- The daemon reads this package for the fleet view and never writes it. The foreman
  (`docs/foreman.md`) opens each goal's draft pull request on `goal/<slug>`
  (a chore's on `chore/<slug>`) before its crew starts, writes each goal's
  `STATE.md` and `rounds/NNN.md`, appends to `facts.md`, and commits and pushes
  the package on the goal's branch after every round; the crew pushes to that
  branch and never to `main`, and the human merges once per goal
- `examples/goals/` holds the generic templates: `LOOP.md` and `facts.md` for the
  project, and `examples/goals/goal/` for one goal folder. `kitterm project init <path>`
  writes the two project files into a project's knowledge directory and registers the
  project; `kitterm project init --refresh <path>` rewrites `LOOP.md` alone from the
  template when the file is byte for byte one of the template's shipped versions
  (`GoalsTemplates.loopHistory`, the SHA-256 of each; a change to the template appends
  the old hash, and `GoalsTemplatesTests` pins the current one) and refuses a file edited
  by hand, a current file, and a symlink, with nothing written; `kitterm project init
  --refresh --check <path>` writes nothing and prints `<path>: current|behind|edited`
  instead (`GoalsTemplates.loopState`, the one comparison both share, so the two can
  never disagree), exiting 0 for all three and 1 for a missing `LOOP.md`, a symlink, or
  a root that is not a directory; `--check` needs `--refresh`; `kitterm goal new <path> <slug>` writes `docs/goals/<slug>/` from the goal
  template with the slug in `STATE.md` and refuses an existing folder; `kitterm goal
  list <path>` prints each goal folder's slug and status; `kitterm goal cost <path>
  [<slug>] [--json]` prints the ledger (`GoalLedger.swift`): per goal and per round,
  dollars, tokens, the cache-read share of input, wall-clock, the API time beside it
  (`totalAPIDuration`, a dash when the round's bill came from a `Cost:` line rather
  than a transcript — that line carries no API time — or predates the bill; the
  goal's total sums only the rounds that have one, because `totalDuration` counts
  the time a session was open, not the time it worked, and a round left open
  overnight otherwise reads as hours of work), tests added (the first
  `N new` of the record's `## Floor`), files changed (`git diff --name-only
  <base>..<result>` from the record's `Base:` and `Result:` shas, a hex word of 7 to 40
  characters, the one with a digit preferred when a line holds both; a dash when a line
  names none or git fails, and then one footer line per such round that says which line
  or what git said, `git diff --name-only X..Y exited 128: fatal: …` (`FilesChanged`,
  `filesChangedReason` in `--json`), because a dash with no reason hid a parser that
  read a digitless sha as no sha, round 2 of `green-ci-again`), the decision and the PR
  a standalone `- Result:` bullet names, else the one riding `Result:` on the
  `- Base:` line (the bullet wins when a record carries both, the same rule
  `KnowledgeSummary.roundRecord` reads the PR by, `record-parsers-agree`), with
  totals per goal and a footer for the rounds that
  predate the bill. For every session a record's
  `Sessions:` line names, the archive's transcript (`agentTranscript`, under
  `KITTERM_STATE_DIR`) wins when `TranscriptBill` reads a bill from it, else the
  record's `Cost:` line at the same position is parsed; `--json` prints one object per
  round with the transcript's field names unrounded and `null` where a line-sourced
  round cannot know a number. `GoalsTemplates.swift` embeds
  both sets and `GoalsTemplatesTests` pins the two equal, so edit the file under
  `examples/goals/` and paste it into the constant. `GoalsLayoutDocsTests` greps
  `AGENTS.md`, `docs/foreman.md`, `docs/architecture.md`, `examples/`, and the embedded
  strings for a path of the old flat layout (a goal file or `rounds/` directly under
  `docs/goals/`, or a `done/` folder) and fails on any
- `kitterm archive cost <id> [--line | --json]` (`ArchiveCommand.swift`) reads an
  archived session's bill with no daemon: it opens the archive's join under
  `~/.kitterm/archive` (`KITTERM_STATE_DIR` moves it) and reads the transcript with
  the same readers `GoalLedger` uses, so the two never disagree on a number.
  `--line` (the default) prints the round record's `- Cost:` line in `LOOP.md`'s
  shape, or `- Cost: none recorded (<reason>)` when the transcript holds no bill;
  `--json` prints the bill as `GET /api/archives/<id>/cost` answers it. The line
  still prints on stdout either way; the exit code is 0 for a bill or a transcript
  with no bill, and 1, with the id and the path on stderr, for an id that is not a
  UUID, a missing archive, a missing transcript join, or a transcript that does not
  open. The foreman archives the session, then runs this command for every session
  the round record's `Sessions:` line names and pastes one `- Cost:` line per
  session, in that order, under the record's header
- `kitterm foreman catch-up [--scope <path>] [--json]` (`ForemanCommand.swift`)
  prints what a new foreman reads first, for the scope directory (`--scope`,
  else the cwd, as a real path) and nothing outside it: the predecessor (the
  newest live or archived session labelled `crew:foreman`, or
  `crew:foreman-<anything>` with no `goal:` label, whose `scope:` label, else
  whose cwd, is the scope or under it; every live one is listed, the caller's
  own `KITTERM_SESSION_ID` left out) with its note and the last assistant text
  of its transcript (`TranscriptLastMessage`, one 256 KiB tail read, a
  `continued-in` record followed), the goals not done of each project whose
  root is under the scope, the live sessions with a `goal:` label, and the
  worktrees under each project's `.claude/worktrees/`. It reads the archives,
  `projects.json` and the goal folders with no daemon, asks `GET /api/sessions`
  for the live rows, says so in one line when the daemon does not answer, and
  writes nothing
- `kitterm foreman watch --session <id> [--session <id> ...] [--since <seq>]
  [--epoch <id>] [--heartbeat <seconds>] [--timeout <seconds>] [--port <n>]
  [--json]` (`ForemanCommand.swift`) blocks on `GET /api/events` (the same
  `MCPTools.Call`/`MCPHTTPClient` path `catch-up` uses: no `curl`, no new
  route) and exits the moment an event whose `session` is one of
  `--session` is a `note`, an `agent.status` of any kind, an
  `approval.pending`, a `command.failed`, or a `session.exited`/`removed`,
  printing it; a non-matching event advances the cursor silently. It also
  exits on a heartbeat (no match within `--heartbeat`, default 1200s) or on
  a daemon epoch change or a pruned cursor, printing that marker instead,
  and always prints the `next`/`epoch` cursor to resume from with no gap.
  With no `--since` it bootstraps at the current head with one no-wait
  poll, so nothing already posted is replayed. `--port` overrides the port
  file, like `mcp`'s own override, for a scratch daemon. It exits non-zero
  when the daemon does not answer, so a caller re-checks rather than loops
  forever.
  It blocks for the run and never daemonizes — it is the command a foreman
  runs in the background (`run_in_background`) and re-invokes itself on, not
  one that returns and keeps going
- `design/` at the root holds every approved design: `foundation.md` (the
  tokens, marks, fonts and rules every page follows), `palette.md`,
  one `.pen` file per surface (`dashboard.pen`, `sessions.pen`) and
  `exports/` (a PNG per approved frame). A goal does not copy a design
  into its `corpus/`; its corpus names the commit of the frames the human
  approved. A crew draws only in the file Pen has open (`facts.md`)
- A chore's line lives in its own file, `docs/goals/chores/<ISO date>-<slug>.md`,
  one file per chore so two chore pull requests opened the same day merge in
  either order with no conflict; `CHORES.md` keeps the lines written before
  2026-09-30 as history and gains no new line
