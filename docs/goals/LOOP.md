# LOOP

The contract for every goal loop in this repository: the authority tiers,
the parsed shapes, the budget, and the stop rules. This file changes when
the process changes.
`STATE.md` changes after every round.

The repository is the control plane. The package is small on purpose.
Two files belong to the project: this file and `facts.md`. Each goal is
one folder under `docs/goals/<slug>/` with `goal.md`, `plan.md`,
`STATE.md`, `corpus/`, and `rounds/`. A new goal is a new folder; a goal
that ends stays where it is with its status in `STATE.md`. There is no
done folder. Add a file only when a round proves the package cannot hold
a fact without it.

Two files, two scopes. `facts.md` holds repository facts by topic, each
dated with its source; only a repository fact goes there, and a
goal-local finding stays in its round record. `STATE.md` holds status,
round counter, queue, failures, proposals, done, and next action, and
nothing else; narrative goes to the records. The card parses the
`- Status:`, `- Round: N of M`, and `## Next action` lines of `STATE.md`,
so their shape is an interface.

## Roles

- **The human** owns rounds. The human writes `goal.md`, `plan.md`, this
  file, and `corpus/`. After each budget the human picks continue,
  redirect, or stop.
- **The foreman** owns turns inside a round, for every project at once. One
  foreman runs per daemon, in a kitterm pane named `foreman` with the label
  `crew:foreman`, on the `foreman-loop` skill and the kitterm MCP tools. It
  delegates every round to a crew session, monitors all of them, and reports
  to the human. It writes `STATE.md`, `rounds/`, and appends to `facts.md`.
  It never edits product code and never answers a permission dialog for a
  crew agent.
- **A crew agent** runs in a session the foreman spawned. It changes the
  product and adds checks. It reports with `post_note`.

## Goal or chore

Not every change is a goal. A goal has a folder, a plan, a corpus, a
budget of rounds, and a direction check; that machinery pays for itself
only when the work needs it. Use this test before creating a folder:

A change is a **goal** when any of these holds:

- its completion condition needs more than one round to prove;
- it changes a contract: a route, a file format, the design in a `.pen`
  file, a token, a public command;
- the human wants to direct it round by round, or wants research before
  the plan.

Everything else is a **chore**: a fix, a wording change, a document, a
dependency bump, a one-file enhancement, a number that drifted. A chore
has no folder. It runs as one crew session with one prompt, one PR, and
one line in `docs/goals/CHORES.md`:

```
- <ISO date> · <what, one sentence> · PR #N · <cost line>
```

Two rules keep the two apart:

- A chore that belongs to a done goal's surface **resumes that goal**
  for one round: set `Status: active`, queue the item, run "One round"
  of the foreman's own procedure, in its skill, write the record, set
  `Status: done` again. It gets the goal's record because the goal's
  corpus is the contract it must keep. Do not create a second goal for
  the same surface.
- A chore that needs a second round is not a chore. Stop, write it up as
  a goal, and tell the human.

The human names goals. The foreman may run a chore on the human's word
without a folder, and says so in the digest.

## Authority

| Tier | Paths | Rule |
|---|---|---|
| Free | `Sources/`, `Web/terminal/src/`, `Tests/` new files, `docs/*.md` except this package, `AGENTS.md`, `examples/`, `STATE.md`, `rounds/`, `facts.md` (append) | The crew and the foreman change these inside a round. |
| Propose | `plan.md`, this file, `docs/adr/`, `.github/workflows/`, `Package.swift`, `Web/terminal/package.json`, `Bench/` | The foreman writes the proposal in the round record with decision `propose`. The human edits the file. |
| Frozen | `goal.md`, `corpus/`, an existing test file, an existing bench scenario and its gate, `Web/terminal/pnpm-lock.yaml` | Nobody changes these inside a round, except a Chartered assertion. A repair that needs one stops the loop. |
| Chartered | an assertion in an existing test file that pins a text, a count, or a layout this round must change | The crew replaces the assertion inside the round and keeps its intent. The foreman records the replacement. |

Before the foreman accepts a round it runs `git diff --name-only <base>` in
the crew session and reads the output. A path under Frozen fails the round.
A path under Propose turns the round's decision into `propose`. A deleted or
weakened assertion in an existing test counts as a Frozen change.

An assertion in an existing test file can pin a text, a count, or a layout.
`goal.md` or the item's proof can require this round to change that text,
that count, or that layout. The assertion is then Chartered, not Frozen. The
crew replaces the assertion inside the round and keeps its intent. The
foreman records the old assertion, the new assertion, and the line of
`goal.md` or `plan.md` that requires the change. A Chartered assertion is
not a proposal: the human does not edit the file, and the round's decision
stays `done`.

The loop can change the product. It can restate the evidence that `goal.md`
charters it to change. It cannot delete or weaken the evidence that decides
whether the product improved.

## Parsed shapes

The product reads the package: the daemon for
`GET /api/projects/<id>/knowledge` and the fleet view, the CLI for
`kitterm goal list` and `kitterm goal cost`, the daemon and the MCP bridge
for the labels. Every shape below names the parser that reads it, so a
reader knows why the shape is fixed. A line that drifts from its shape is
not an error: the parser leaves the field absent, and the product no
longer sees it.

### `STATE.md`

`KnowledgeSummary` parses `STATE.md` for `GET /api/projects/<id>/knowledge`,
the fleet view, and `kitterm goal list`. The shape:

```markdown
# STATE: <slug>

- Status: active | waiting | stopped | done
- Round: <n> of <m> in this budget (<ordinal> budget)
- Rounds total: <n>
- Last floor: green | red (<check>) (<ISO date>, round <n>)
- Updated: <ISO date>

## Queue
## Failures
## Proposals waiting on the human
## Done
## Next action
```

The card parses the `- Status:`, `- Round: N of M`, and `## Next action`
lines, so their shape is an interface. Keep the five bullets at the top
and the five sections in this order. What each parser takes:

- `- Status:`: the value is the goal's status (`KnowledgeSummary.status`);
  `kitterm goal list` prints it and the route orders the goals by it
  (`KnowledgeSummary.isOrderedBefore`).
- `- Round: N of M`: `N` and `M` are the leading digits of the first and
  the third word, so `3 of 3, budget spent` keeps the budget
  (`KnowledgeSummary.roundCounter`).
- `- Last floor:`: the value, whole (`KnowledgeSummary.lastFloor`).
- `- Rounds total:` and `- Updated:`: no parser reads them. The template
  writes them, `GoalsLayoutDocsTests` pins the five bullets and the five
  sections, and "One foreman for every project" orders the schedule by
  `Updated`.
- `## Next action`: the first paragraph, capped at 512 bytes
  (`KnowledgeSummary.nextAction`).
- `## Proposals waiting on the human`: the top-level bullets are counted
  (`KnowledgeSummary.proposals`); the fleet view marks the goal
  `[needs you]` while the count is above zero.
- `## Queue`, `## Failures`, `## Done`: the goal's tasks, in that order,
  with the states `pending`, `failed`, `done` (`KnowledgeSummary.tasks`).
  An item is a column-0 `- `, `* ` or `N. ` line; an indented line is a
  continuation. Its slugs are the backticked kebab words on its first line
  before the first comma, so ``- `a` (1) and `b` (2), round 1, `9784fd2`.``
  yields `a` and `b` and not the sha; `round N` and `PR #N` come from the
  whole first line. Prose under a heading (`None.`) names no task. A slug
  in two sections keeps the state a reader needs most, `failed` over
  `pending` over `done`, at its first position. The fleet view lists every
  task that is not done and the first two done ones under the goal.

### The round record

Write `<slug>/rounds/NNN.md` with this shape. Three-digit number, one file per
round, never rewritten after the round ends.

```markdown
# Round NNN: <queue item>

- Goal: <slug>
- Started: <ISO date>  Ended: <ISO date>
- Sessions: <id>, <id>   Archives: <id>
- Base: <git sha>   Result: <git sha or PR #>
- Cost: $D · Nk in (C% cached) · Nk out · Hh Mm

## Prompt
<the request sent, verbatim or a path to it>

## Floor
before: green | red (<check>)   after: green | red (<check>)

## Effects
- behaviour: <what the crew did>
- visible: <screenshot path, test name, URL>
- persistent: <files, state, records>

## Gap
class: world | domain | contract | runtime | steering | surface | harness | none
evidence: <one line>

## Decision
done | failed | propose (<path>: <what and why>)

## Reflection
<what cost time that a rule or a check could prevent>
```

On the `Cost:` line, `$D` is `totalCostUSD` rounded to the cent; `Nk in`
is `inputTokens` plus `cacheCreationInputTokens` plus
`cacheReadInputTokens`, summed over every model in `modelUsage`; `C%
cached` is the summed `cacheReadInputTokens` over `in`, rounded to a
whole percent; `Nk out` is `outputTokens`; each token count is rounded to
whole thousands; `Hh Mm` is `totalDuration` rounded to whole minutes.
When `GET /api/archives/<id>/cost` answers `hasBill: false` or 404, the
line reads `- Cost: none recorded (<reason>)` with the reason the route
gave.

Archive the session, then read `GET /api/archives/<id>/cost` for every
session the record's `Sessions:` line names and write one `- Cost:` line
per session, in that order, under the record's header.

Two parsers read the record:

- `KnowledgeSummary.roundRecord`, for `rounds` of
  `GET /api/projects/<id>/knowledge` and the fleet view: the file name
  `NNN.md` is the round number; the queue item is what follows
  `# Round NNN:`; the day is the `YYYY-MM-DD` the `- Started:` line begins
  with, and a record with no day is in no range of the fleet view; the cost
  and the duration sum the header's `- Cost:` lines, the lines before the
  first `## ` heading, a `none recorded` line skipped
  (`KnowledgeSummary.costLine`); the pull request is the first `PR #N` on
  the `- Result:` line, so a result given as a sha names none; the
  correction is a `## Correction` heading.
- `kitterm goal cost` (`GoalLedger`): the ids on the `- Sessions:` line
  and after `Archives:`; the sha on the `- Base:` line and the sha or the
  `PR #N` after `Result:`; the `- Cost:` line at the same position as each
  session the `Sessions:` line names, read when the session's archived
  transcript holds no bill; the first `N new` under `## Floor` as the
  tests added; the first word under `## Decision` as the decision.

### Labels

| Key | Value | Set by |
|---|---|---|
| `crew` | goal slug; `foreman` for the foreman's own pane; `helper` for a session a crew spawns inside a round | foreman, or the crew for a helper |
| `goal` | goal slug | foreman |
| `round` | round number | foreman |
| `task` | queue item slug | foreman |
| `resumed-from` | archive id, or the id the pane held before an epoch change | foreman, on a respawn |

Filter the fleet by any label: `list_sessions label="goal:<slug>"`.
`SessionLabels` names the keys the loop reserves and passes them through
on every session row; the fleet view joins a live session to its goal
folder by `goal:<slug>` and marks the queue item `[working]` by
`task:<slug>` under it. A session the crew spawns inside the round
carries `crew:helper` with the round's `goal:` and `round:` labels, and
the crew ends it.

## Budget

- Three rounds per direction check. `STATE.md` counts them.
- One correction per round. A second failure ends the round as failed.
- A round attempt the host machine kills does not spend the budget and
  writes no round record. Note it in `STATE.md` under `Failures` as
  `attempt killed: <ISO date>, <what died>`. Leave the round counter and
  the queue item where they are. Run the round again. A failed round is
  the other case: it spends the budget and it gets a record.
- One crew session per round, plus review sessions when the round's
  capability touches `Sources/KittermDaemon/PtySession.swift` or
  `HTTPAPIHandler.swift`.
- Commit after every round. The record, the state, and any fact go into
  one commit on the goal's branch before the foreman reports the digest. A
  record that sits uncommitted is not written.

## One foreman for every project

The foreman keeps no state of its own. The repositories are the control
plane; the foreman rebuilds its view from them and from the daemon.

1. **Scan.** On start, and after every event batch, list the projects
   (`list_projects` once capability 1 ships; until then the paths the human
   gave). For each project read every `docs/goals/<slug>/STATE.md`. A
   project with no goal folder is reported once as "no goal" and skipped.
   The folder name is the goal's slug; the `goal:` label carries it. Match
   a live session to its goal by the `goal:` and `round:` labels, never by
   id. The round's own session is the one with `crew:<slug>`; a
   `crew:helper` session beside it is a fixture the crew made. A round is
   open while a live session carries `crew:<slug>`; a `crew:helper` session
   does not hold the round open.
2. **Schedule.** A goal is runnable when its `Status` is `active`, its
   budget has rounds left, no round is open, and no proposal blocks the next
   action. `Status` is one of `active`, `waiting`, `stopped`, `done`; only
   `active` runs. Run at most one round per goal and at most three crew
   sessions across all projects. A review session and a crew's helper count
   toward the cap of three. Start the runnable goal with the oldest
   `Updated` date first.
3. **Delegate.** Run "One round" of the foreman's own procedure, in its
   skill, for that goal. The crew session does the work. The foreman
   reads, routes, verifies, and records.
4. **Monitor.** Hold one `wait_for_events` for the whole daemon. On each
   scan compare `heldSince` with now: archive a crew session that sits at an
   empty prompt one hour past `completed`. Respawn a crew once after an
   `epoch` change; when the respawn does not restore the round, record a
   killed attempt (see "Budget") and stop the goal.
5. **Report.** See "Reports" of the foreman's own procedure, in its skill.

## Direction

After a goal spends its budget the foreman sets its `Status` to `waiting`,
reports, and keeps the other goals running. At every direction check the
human prunes `facts.md` and the goal's open proposals. The human answers
per goal:

- **continue**: the foreman resets `Round: 0 of 3`, sets `Status: active`,
  and notes the decision in `STATE.md`.
- **redirect**: the human edits `goal.md` or `plan.md`, then says continue.
- **stop**: the foreman sets `Status: stopped` and archives or ends the
  goal's crew sessions. The folder stays where it is.
- **done**: when the completion condition in `goal.md` holds, the foreman
  sets `Status: done`, notes the date, and stops scheduling the goal. The
  folder stays; the human can reopen it with `Status: active` and a new
  queue at any time.
- **new goal**: the human names a slug. The foreman creates
  `docs/goals/<slug>/` from the template (`kitterm goal new <path> <slug>`
  once it exists), and the human writes `goal.md`, `plan.md`, and the
  corpus before the first round.

## Stop rules

The foreman stops one goal and tells the human when:

- the budget is spent;
- a repair needs a change under Frozen;
- the floor is red at the start of two rounds in a row;
- a failure does not reproduce in a fresh session;
- the crew session reports `exited` with a non-zero code twice;
- the daemon `epoch` changes and the crew is gone (respawn once, then stop).

A stopped goal does not stop the foreman. The other goals keep running.
