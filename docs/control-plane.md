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
- `kitterm round open <root> <slug> --task <item> [--chore] [--title <text>]
  [--body <text>] [--knowledge <dir>] [--port <n>] [--json]`
  (`RoundCommand.swift`) does every step of a round before the crew's prompt,
  in this order:
  1. `daemon`: `GET /api/sessions`. A session that has not exited and
     carries `crew:<slug>` refuses the round, and nothing changes.
  2. `base`: the base branch by `KnowledgeBase.baseBranch` (`origin/HEAD`,
     else `main`, else `master`), then a fetch of it.
  3. `branch`: `goal/<slug>` (`chore/<slug>` with `--chore`), from the local
     branch, else `origin/<branch>`, else `origin/<base>`.
  4. `worktree`: `<root>/.claude/worktrees/<slug>` on that branch.
  5. `goal`: the goal folder in the worktree holds `STATE.md` with the item
     under `## Queue`. The round is the highest `rounds/NNN.md` plus one. A
     chore has no folder and gets one empty opening commit.
  6. `pull request`: the open pull request of the branch (`gh pr list
     --head`). With none, the command writes `, round R.` on the queue line,
     commits the goal folder, pushes, and runs `gh pr create --draft`.
     `--title` defaults to `<slug>: <goal.md title>`, `--body` to a pointer
     at `goal.md`.
  7. `queue line`: the item's first line becomes `<head>, round R, PR #N.`;
     the command commits the goal folder and pushes, never with force.
  8. `spawn`: `POST /api/sessions` with the worktree as cwd, the name
     `<slug> round <R>` (the slug for a chore), and the labels `crew`,
     `goal`, `round`, `task` and `pr` (`crew`, `task` and `pr` for a chore).
     It types no input and starts no `claude`.

  It prints `session`, `worktree`, `branch`, `pr`, `round` and `base` (the
  worktree's `HEAD` after the last push), one per line; `--json` prints one
  object with the same keys plus `task`, `slug` and `chore`. Each step reuses
  what exists, so a second run after a failure continues: it does not create
  a branch, a worktree or a pull request twice. A failure prints
  `round open: <step> failed: <reason>` and what already exists, and exits 1.
  It never merges, force-pushes or marks a pull request ready. Every `git`
  and `gh` runs through one `Runner`, so `RoundOpenTests` uses a fake `gh`, a
  scratch repository with a bare remote, and a scratch daemon in process
- `kitterm round close <root> <slug> [--chore] [--commit] [--round <n>]
  [--bill-timeout <s>] [--foreman-session <id>] [--knowledge <dir>]
  [--port <n>]` (`RoundCloseCommand.swift`, the text in `RoundRecord.swift`)
  does every step after the crew's `DONE` note that needs no judgment, in
  this order:
  1. `daemon`: `GET /api/sessions`.
  2. `worktree`: `<root>/.claude/worktrees/<slug>`, its branch, and the goal
     folder in it (`chores/` with `--chore`).
  3. `sessions`: the round is `--round`, else the `round:` label of the live
     sessions with `crew:<slug>`, else of the newest archive with it. The
     round's sessions are the live and the archived ones with
     `crew:<slug>`, `goal:<slug>` and `round:<R>` (`crew:<slug>` alone for a
     chore). A helper with `crew:helper` is not one of them.
  4. `archive`: `POST /api/sessions/<id>/archive` for each live one.
  5. `bills`: `ArchiveCommand.answer`, the reader of `kitterm archive cost`,
     for each session, again every 2 s until every bill reads or
     `--bill-timeout` (default 60 s) ends. A session still without a bill
     gets `- Cost: none recorded (<reason>)`.
  6. `record`: `rounds/NNN.md` in the shape of `LOOP.md`, "The round
     record", written once and never rewritten. The title is the `task:`
     label. `Started` is the first `timestamp` of the earliest session's
     Claude Code transcript, because a session row carries no creation
     time; `Ended` is the time of the run. `Sessions:` names each model in
     parentheses. `Base:` is the merge base with `origin/<base>` on round 1,
     else the `Result:` sha of the previous record; `Result:` is the
     worktree's `HEAD`, the branch and `PR #N` from the `pr:` label. One
     `- Cost:` line per session follows, then one `- Foreman:` line: the
     turns of the transcript of the session `KITTERM_SESSION_ID` names
     (`--foreman-session` overrides) stamped between `Started` and `Ended`,
     its subagents' too, priced by `ModelPricing`
     (`TranscriptEstimateCache.estimate(forTranscriptAt:from:to:)`), as
     `- Foreman: ~$D · Nk in (C% cached) · Nk out`, or
     `- Foreman: none recorded (<reason>)` with no session, no transcript or
     no turn. A model `ModelPricing` does not know adds
     ` · unpriced <model>`: its tokens count and its dollars do not. The six sections each hold the marker line
     `[foreman writes this]`; `Floor` holds two, `before:` and `after:`.
  7. `state`: `- Round: n` grows by the rounds `- Rounds total:` has not
     counted, `- Rounds total:` becomes R, `- Updated:` becomes the day, and
     the item moves from `## Queue` to `## Done` as
     ``- `<item>`, round R, `<sha>`, PR #N. See `rounds/NNN.md`.``.
     `Status` and `Last floor` stay the foreman's.
  8. `commit`, with `--commit` only: it refuses while a marker line remains
     in the record, then makes one commit of the goal folder and pushes it,
     never with force.

  `--chore` writes `chores/<ISO date>-<slug>.md` in place of steps 6 and 7:
  the marker, the model, `PR #N` and the cost line. The command prints
  `file`, `round`, `sessions` and `markers`, and `commit` after `--commit`.
  A second run reuses the archives, the record and the `STATE.md` edit. A
  failure prints `round close: <step> failed: <reason>` and what already
  exists, and exits 1. It never merges, never marks a pull request ready,
  and runs no floor. `RoundCloseTests` proves each field with a scratch
  repository, a scratch daemon in process and fixture transcripts.
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
