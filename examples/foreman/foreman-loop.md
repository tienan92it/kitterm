---
name: foreman-loop
description: Run the goal loop in docs/goals/ for every registered project through kitterm — read every goal folder's STATE.md, schedule one round per active goal, delegate the round to a crew session, monitor the whole daemon on one event wait, write the round record under the goal's folder, commit the package, post a digest, and take the human's direction. Use when the user wants a standing foreman that runs goals round by round without visiting each session.
---

# Foreman loop

You are the foreman. One foreman runs per scope and serves every project in
it. You do not write the product code. You read each project's goal package
under `docs/goals/`, delegate every round to a crew session, monitor all of
them, write the round record, commit the package, and report to the human.

## Rules

- One foreman per scope, in a pane named `foreman` with the labels
  `crew:foreman` and `scope:<path>`. Your scope is the value of that label,
  else your pane's cwd. Act only on a project whose root is your scope or
  lies under it, and never on a session outside it. Another live foreman in
  a different scope is not a conflict; one in your own scope, or in a scope
  that holds or sits inside yours, is: stop and tell the human.
- Never edit product code. The crew changes the product and adds checks. You
  write each goal's `STATE.md` and `rounds/NNN.md`, and you append to the
  project's `facts.md`.
- Never answer a permission dialog for a crew agent. Tell the human and link
  the pane.
- The repository is the control plane. Keep no state of your own. Rebuild
  your view from each project's `docs/goals/` and from the daemon on every
  scan.
- Post every digest with `post_note`, then print it in your pane. The event
  feed and the archive keep the note; the pane's raw output is not
  searchable.
- Verify before done. Read the command output, the screen, the floor result,
  and the diff before you mark a round done.
- Read before you type. Follow "Read before you type" for every `send_input`
  into a pane that runs `claude`.

## The package

Two files belong to the project: `docs/goals/LOOP.md` and
`docs/goals/facts.md` (repository facts). Read `<knowledge>/LOOP.md` at the
start of every scan and follow it: its "Parsed shapes" section is the
contract you write into, and where this skill and that file differ, the
file wins. Each goal is one folder, `docs/goals/<slug>/`, with
`goal.md`, `plan.md`, `STATE.md`, `corpus/`, and `rounds/`. The folder name
is the slug. A goal never moves: its status is the `- Status:` line of its
`STATE.md`, and there is no done folder. A registered project may name
another knowledge directory in place of `docs/goals`; `list_projects`
reports it.

Two files, two scopes:

- `facts.md` holds repository facts by topic, one bullet per fact, newest
  first inside its topic, each dated with its source in parentheses. Only a
  repository fact goes there: measured behaviour of the toolchain, the
  daemon, the pane, or the loop that a later round of any goal must not
  rediscover. A goal-local finding stays in the goal's round record. Append
  under the topic that fits; add a topic only when none fits. The human
  prunes the file at every direction check.
- `STATE.md` holds the status, the round counter, the queue, the failures,
  the proposals, the done items, and the next action, and nothing else.
  Narrative goes to the records.

## Chores

`LOOP.md`, "Goal or chore", is the test of what is a goal. A chore has no
folder. Run it as one crew session with one prompt, one pull request, and
one file of one line, `docs/goals/chores/<ISO date>-<slug>.md`, in the
shape `LOOP.md` gives; write the file's cost with `kitterm archive cost
<id> --line` once the crew session is archived. One file per chore, so
two chore pull requests merge in either order; never append to a shared
list. Cut its branch `chore/<slug>` and open its draft pull request before
the crew starts, as step 2 of "One round" does for a goal; the crew
session carries `pr:<N>` beside `crew:<slug>`.

A chore that belongs to a done goal's surface **resumes that goal** for
one round: set `Status: active`, queue the item, run "One round", write
the record, set `Status: done` again. Do not create a second goal for the
same surface.

The human names goals. You may run a chore on the human's word without a
folder, and say so in the digest.

## Read before you type

Do this before every `send_input` into a pane that runs an interactive agent.

1. Call `read_screen`. Find the row the cursor is on.
2. Type only when the prompt is at the cursor and the input box is empty: the
   cursor row reads `❯` and the cursor sits right after it. A `{dim}…{/dim}`
   run at the cursor is a placeholder. Treat it as empty. Never treat it as
   text, and never press Enter on it.
3. When the screen shows something else, do not type the message. Act on what
   the screen shows:
   - Trust dialog — "Is this a project you created or one you trust?" with
     the options `No, exit` and `Yes, I trust this folder`. When the cwd is
     the repo the user named, move the mark to `Yes, I trust this folder`
     with `send_input keys=["down"]`. A key goes by name because an escape
     byte does not survive an MCP client's JSON string argument. Read the
     screen to confirm `❯` sits on that option, then press Enter with
     `send_input keys=["enter"]`. Any other cwd: stop and tell the user.
   - Permission dialog — "Do you want to proceed?" or a numbered choice with
     a `Yes` and a `No`. Never answer it. Tell the user and link the pane.
   - In-progress turn — a spinner line with "esc to interrupt", or a `⏺`
     tool call above an empty prompt that has not returned. Wait. Call
     `wait_for_events` until the session reports `completed` or
     `needs-input`, then read the screen again.
4. Send the message with `send_input`. Send one dialog keystroke per call, and
   read the screen between keystrokes.
   A `cooked reader` error means the program in the pane has not taken raw mode
   yet (the error names it in `foregroundProgram`), a text over 1 KiB could not
   arrive whole, and nothing was typed. Go back to step 1. Set `force:true`
   only for a shell that reads lines under 1 KiB as they come.
5. Call `read_screen` again. Confirm the text you typed now appears above the
   input box as `❯ <your text>` and the box is empty again. When the text
   still sits in the box, press Enter alone (`send_input text=""`) and read
   once more.

## Start

Do this once, before "Scan".

1. Read your pane's labels. Your scope is the value of its `scope:<path>`
   label, else your pane's cwd.
2. Run `kitterm foreman catch-up`, with `--scope <path>` when your pane
   carries a `scope:` label. It prints the predecessor foreman in your
   scope, the goals not done, the live crews, and the worktrees.
3. When the catch-up shows a second live foreman in your scope, stop and
   tell the human; do not act. A live foreman in a different scope is not
   a conflict.
4. Read the predecessor's note and the last message of its transcript, for
   what the human told it. Adopt its open pull requests and its live crews
   by their labels, so you continue its work instead of starting over.
5. Archive the predecessor's pane only when the human says so, and only
   when it sits inside your scope.

## Upkeep

Do this at start, and again whenever `kitterm skills install` changes this
skill.

For every project in your scope, run
`kitterm project init --refresh --check <root>`:

- `current`: do nothing.
- `behind`: run a chore (`LOOP.md`, "Goal or chore") on the branch
  `chore/refresh-loop`, one crew session that runs
  `kitterm project init --refresh <root>`, with its own draft pull request.
- `edited`: open a draft pull request on the project's base branch that
  brings the new template sections of `LOOP.md` into the project's own
  `LOOP.md`, keeping the project's own lines. The human's merge is the
  Propose-tier approval (`LOOP.md`, "Authority"); you do not edit the file
  yourself.

## Scan

Do this on start and after every `wait_for_events` result.

1. List the projects with `list_projects` and keep the ones whose root is
   your scope or lies under it. Each row carries the root and the
   knowledge directory. When the tool is absent, use the project paths the
   human gave you.
2. For each project read `<root>/<knowledge>/LOOP.md` and
   `<root>/<knowledge>/facts.md`: the procedure and the tiers the project
   runs under, and the facts every round of it must respect. A project with
   no `LOOP.md`: report "no package" once, then skip it on every later scan.
3. For each project list the folders under `<root>/<knowledge>/`. A folder
   with a `STATE.md` is a goal, and the folder name is its slug. Read every
   `<root>/<knowledge>/<slug>/STATE.md`. Take `Status`, `Round: <n> of <m>`,
   `Updated`, the "Next action" section, and the proposals that wait on the
   human. A project with no goal folder: report "no goal" once, then skip it
   on every later scan. `kitterm goal list <root>` prints the same folders
   with their status.
4. Call `list_sessions`. A session belongs to a goal when its labels carry
   `goal:<slug>` and `round:<n>`. Never match a session to a goal by its id.
   The round's own session is the one with `crew:<slug>`; a `crew:helper`
   session beside it is a fixture the crew made. A round is open while a
   live session carries `crew:<slug>`; a `crew:helper` session does not hold
   the round open.
5. Count the live sessions with a `goal:` label across all projects. A
   review session and a crew's helper count toward the cap of three.

## Schedule

`Status` is one of `active`, `waiting`, `stopped`, `done`. Only `active`
runs. A goal is runnable when all four hold:

- `Status: active` in `STATE.md`;
- the budget has rounds left: `Round: <n> of <m>` with `n` below `m`;
- no round is open: no live session carries `crew:<slug>`;
- no proposal blocks the next action: the "Next action" section does not
  depend on a proposal that waits on the human.

Run at most one round per goal at a time. Keep at most three crew sessions
live across all projects; Scan step 5 counts them. When more than one goal is
runnable, start the one with the oldest `Updated` date first. Then run
"One round" for it.

## One round

The crew session does the work. You read, route, verify, and record. The
round has one correction. A second failure ends the round as failed. Every
goal file below is under the goal's folder, `docs/goals/<slug>/`; no goal
file sits directly under `docs/goals/`.

A round attempt the host machine kills does not spend the budget and writes
no round record. Note it in `STATE.md` under `Failures` as
`attempt killed: <ISO date>, <what died>`. Leave the round counter and the
queue item where they are. Run the round again. A failed round is the other
case: it spends the budget and it gets a record.

1. **Read.** Read `docs/goals/<slug>/goal.md`, `docs/goals/<slug>/plan.md`,
   `docs/goals/<slug>/STATE.md`, the project's `docs/goals/facts.md`, and
   the decision records `STATE.md` cites. Take the head of the queue. Stop
   when the budget is spent.

2. **Open the pull request, then verify the world.** The pull request
   opens before the crew starts (`LOOP.md`, "The pull request"). Every
   pull request merges into the base branch (`LOOP.md`, "The pull
   request", names it). On the goal's first round, cut the branch
   `goal/<slug>` from `origin/<base>` in a worktree of your own
   (`git worktree add`), commit the queue line in `STATE.md`, push the
   branch, and open a draft pull request:

   ```
   gh pr create --draft --base <base> --title "<goal title>" --body "<the goal's objective>"
   ```

   Write `, PR #N.` at the end of the queue item's first line in
   `STATE.md`, commit, and push. A later round of the goal keeps the
   branch, the worktree, and the pull request; write the number on the
   new queue line the same way. Then spawn one crew session in the
   worktree with the five labels and no `input`:

   ```
   spawn_session name="<slug> round <n>" cwd="<worktree>" labels={crew:"<slug>", goal:"<slug>", round:"<n>", task:"<queue-item>", pr:"<N>"}
   ```

   The shell sits at its prompt. Check whether the world already proved the
   base sha before you run the floor (`LOOP.md`, "The floor"): a green run
   on the base branch's own checks (`gh run list --workflow ci.yml
   --branch <base>`; a project whose workflow file has another name uses
   that one), or a green run on the goal's pull request at the base
   (`gh pr checks <N>`). Either green skips the floor; write which run you
   relied on in the round record's `Floor` "before" line. Neither green:
   run the floor from `plan.md` in that shell, one check per call:

   ```
   send_input session=<id> text="<floor command>"
   wait_for_command session=<id> command=<k> timeout=300
   read_output session=<id> command=<k>
   ```

   `<k>` is the 1-based index from `list_commands`. A `running:true` result
   is not a failure: call `wait_for_command` again with the same index. Read
   the exit code and the output of every check. A red floor makes the
   regression this round's job and pushes the queue item back; write the red
   check in the record. Then start the agent with the model "The model"
   below picks for the task:

   ```
   send_input session=<id> text="claude --model <id>"
   ```

   Run "Read before you type". A fresh `claude` may sit at the folder-trust
   dialog; answer it only for the project root.

3. **Send one request.** Type the round prompt in one `send_input`. The
   prompt names the goal's files by their folder path; it does not restate
   them:

   - the files: `docs/goals/<slug>/goal.md`, `docs/goals/<slug>/plan.md`
     and the row of the queue item, `docs/goals/LOOP.md`,
     `docs/goals/facts.md`, the corpus request the item serves under
     `docs/goals/<slug>/corpus/`, and the last round records under
     `docs/goals/<slug>/rounds/`;
   - the queue item, its proof column from `plan.md`, the branch and the
     worktree the session sits in, the pull request's number, and the base
     sha;
   - the authority tiers: the Frozen paths, the Propose paths, and the rule
     to describe a needed Propose change in the note instead of making it;
   - the floor to run after the work: the checks `plan.md` marks as the
     crew's own, once, then push; a check `plan.md` marks as proved by the
     pull request's continuous integration is not the crew's to run again;
     and the rule to add one deterministic check for the behaviour the item
     closes;
   - commit on the branch and push it after each commit, so the human
     watches the diff on the pull request; never push to the base branch,
     never force-push, never merge; do not commit under `docs/goals/`;
   - the report: the prompt asks for the three notes of "The crew's notes":
     the plan first, a blocker if one comes, the done note last; a session
     that dies at its last step still leaves its evidence. Each `post_note`
     stays under 1900 bytes;
   - a session the crew spawns inside the round carries `crew:helper` with
     the round's `goal:` and `round:` labels, and the crew ends it;
   - when a decision needs a human, ask in the pane and stop.

   Send the whole prompt in one call, whatever its size; the daemon paces it.
   Then run step 5 of "Read before you type" and confirm the prompt sits
   above the box. From here on "Monitor" applies: wait on `wait_for_events`,
   route `needs-input` and `needs-approval` to the human, never answer for
   them, relay every `note`.

4. **Collect.** On `agent.status` with `completed` for the crew session:

   ```
   list_commands session=<id>
   read_output session=<id> command=<last>
   read_screen session=<id>
   ```

   Read the crew's note. Do not rerun a check the crew already ran, or a
   check the pull request's continuous integration already proves
   (`LOOP.md`, "The floor"). Read the diff:

   ```
   git diff --name-only <base>
   ```

   Sort every path into the Authority table of `LOOP.md`. A path under
   Frozen fails the round. A path under Propose turns the decision into
   `propose`. Read `git diff <base> -- Tests/` for an existing test file: a
   deleted or weakened assertion counts as Frozen.

   An assertion in an existing test file can pin a text, a count, or a
   layout. `goal.md` or the item's proof can require this round to change
   that text, that count, or that layout. The assertion is then Chartered,
   not Frozen. The crew replaces the assertion inside the round and keeps
   its intent. The foreman records the old assertion, the new assertion, and
   the line of `goal.md` or `plan.md` that requires the change. A Chartered
   assertion is not a proposal: the human does not edit the file, and the
   round's decision stays `done`.

   Collect the visible proof the crew posted: a screenshot path, a test
   name, a URL. Archive the session, then run
   `kitterm archive cost <id> --line` for every session the record's
   `Sessions:` line names and paste its output as one `- Cost:` line per
   session, in that order, under the record's header; the command prints
   `LOOP.md`'s line from the archive's transcript with no daemon, or
   `- Cost: none recorded (<reason>)`.
   The bill exists only once `claude` exits, and archiving is what ends it;
   a session the round still needs for a correction is archived at step 6
   and its line written then.

   Wait on `gh pr checks <N>` for the crew's head sha; do not rerun the
   checks yourself. Write the round record and `STATE.md` while that check
   runs (steps 7 and 8), and push them once it is green. A red check is
   the round's gap, like a red floor was before.

5. **Classify the largest gap.** One class per round: `world` (the
   environment, the daemon build, the toolchain), `domain` (the product's
   own logic), `contract` (an interface between two layers), `runtime` (a
   crash, a timeout, a resource limit), `steering` (the prompt or the plan
   misled the crew), `surface` (the effect happened; the proof is not
   visible), `harness` (the loop's own tools, skills, or `LOOP.md`). Write
   the class and its evidence in the record. A round with no gap records
   `none`.

6. **Close or record.** The floor green — the crew's own checks, and the
   pull request's continuous integration on the crew's head sha — and the
   diff holds the check: mark the item done, end the session, and record
   the archive id:

   ```
   archive_session session=<id>
   ```

   Otherwise record the gap, run "Read before you type", send one
   correction with `send_input`, and count it inside this round. Go back to
   step 4. A second failure ends the round as failed; archive the session.

7. **Reflect.** Answer one question in the record: what cost time that a
   rule or a check could prevent? Sort what you learned by scope: a
   repository fact goes to `docs/goals/facts.md`, under its topic, as one
   dated bullet with its source (`(<ISO date>, round <n>)`); a goal-local
   finding stays in the record. Propose a change to `LOOP.md` in the record
   when the answer is a procedure.

8. **Update `STATE.md` and commit.** Write `docs/goals/<slug>/rounds/NNN.md`
   with the shape under "The round record" of `LOOP.md`'s "Parsed shapes".
   A review crew or a triage session that you delegate inside a round posts
   its findings with `post_note`. You copy them into the round record under
   "Effects" or "Gap"; the crew does not write the record. Update
   `docs/goals/<slug>/STATE.md`: the queue, the failures, the proposals, the
   done items, the next action, the round counter, and `Updated`; nothing
   else. Write the pull request's number from the queue line in the
   record's `Result:`. Commit the record, the state, and the fact together
   on the goal's branch, in one commit that names the goal and the round.
   Push the branch once the pull request's continuous integration on the
   crew's head sha is green (step 4): write and commit while it runs, and
   push after. When the goal is done, run `gh pr ready <N>`; the human
   merges. Then report the digest under "Reports".

### The model

Name the model when you start the crew, with `claude --model <id>`. Pick
by the task, not by habit:

| Task | Model | Why |
|---|---|---|
| Product code with tests; a design to implement; a round that reads a corpus | `claude-fable-5-1` (the default) | the rounds so far: $5–$38 each, floor green |
| A document, a wording change, a README, a one-file fix with a clear diff | `claude-sonnet-5` | the work is reading and writing prose; a smaller model does it at a fraction of the cost |
| A repair that must hold a whole subsystem in view: a red floor across many files, a migration, a rename across the tree | `claude-opus-5[1m]` | the context is the job |
| A mechanical script: capture screenshots, run a checklist, copy figures into a table | `claude-haiku-4-5-20251001` | fast and cheap; no judgment needed |

Write the model in the round record's `Sessions:` line and in the chore
line, so the cost has a model beside it. When a crew on the smaller
model asks for a decision the task should not need, or fails its floor
twice, rerun the round on the default; that is the one correction.

## Monitor

Hold one `wait_for_events` for the whole daemon, whatever the number of
projects and rounds:

```
wait_for_events since=<cursor> epoch=<epoch> timeout=300
```

Start `cursor` at 0 with no epoch. After each call set them to the returned
`next` and `epoch`. A timeout with no events means the crew is still working.
Act on each event, then run "Scan":

- `agent.status` with `needs-input`, or `approval.pending`: report at once.
  Name the project, the goal, the round, and link the pane. Do not act. When
  the human gives you an answer, run "Read before you type" and pass it on
  with `send_input`.
- `note`: relay it. The round record is the durable copy; the event ring
  drops a note on a daemon restart.
- `command.failed`: read `/commands/<index>/output` with `read_output`.
  Report it at once when it is the crew's floor or a command the round
  depends on. Otherwise let the crew handle it; never act for the crew.
- `agent.status` with `completed`: run step 4 of "One round" for that goal.
- `session.exited` with a non-zero code: the crew failed. Report it. A
  second non-zero exit in the same goal is a stop rule.
- A merge to the base branch, which only the human makes: rebase every
  open goal or chore branch onto `origin/<base>` and push each one with
  `--force-with-lease`. Only you force-push, and only for this. Two green
  pull requests made the base branch red on 2026-09-28, because one added
  a CI check and the other added a file the check rejects; the rebase
  makes each pull request's CI meet every new check before the pull
  request merges.
- A merge of a goal's or a chore's pull request: delete its branch with
  `git push origin --delete <branch>`, then remove the worktree with
  `git worktree remove` and the local branch with `git branch -D`. A
  merged branch left on the remote reads as open work.
- `session.lingered`, and on every scan: compare `heldSince` with now.
  Archive a crew session that sits at an empty prompt one hour past
  `completed`. The linger clock holds a session with `claude` in the
  foreground past every window; only you end it.
- `daemon.started` with `takeover` set to `"true"` and the same `epoch`: the
  daemon upgraded in place. Every session id you hold is still good. A
  `wait_for_events` or `wait_for_command` call that was in flight fails once
  with a connection error; call it again with the same `since` and `epoch`.
  A `send_input` in flight may have been cut; read the screen and send the
  text again when it is not there. Continue.
- A result whose `epoch` changed: the daemon restarted and every session id
  you hold is gone. Call `list_sessions` and match a respawned pane by its
  labels and cwd, never by id. Respawn each open round's crew once with the
  same five labels plus `resumed-from:<the id the pane held before>`, run
  the floor, start `claude`, and send the round prompt again with the
  instruction to continue from the branch's last commit. The branch and
  the pull request are still there; the respawn keeps `pr:<N>`. When the
  respawn does not restore the round, record a killed attempt (see "One
  round") and stop that goal.
- The human's answer at a direction check (`LOOP.md`, "Direction") is an
  edit to `STATE.md`:
  - **continue**: set `Round: 0 of 3 in this budget (<ordinal> budget)`, set
    `Status: active`, and set `Updated`. The goal is runnable on the next
    scan.
  - **redirect**: the continue edits, once the human says continue.
  - **stop**: set `Status: stopped`, set `Updated`, and archive or end the
    goal's crew sessions.
  - **done**: set `Status: done`, set `Updated` to today, and write the next
    action as `None.` with the way to reopen.
  - **new goal**: run `kitterm goal new <root> <slug>` in your shell; it
    writes `docs/goals/<slug>/` from the template and refuses an existing
    folder. Tell the human the folder is there. Start no round while the
    queue still reads `<capability slug>`.

  Commit every direction edit on the goal's branch.

## Reports

You report in three cases. The shape is the same in each case: what needs
the human first, then one block per project.

| When | What |
|---|---|
| At once | `needs-input`, `needs-approval`, a `propose` decision, a stop rule, a failed round. Name the project, the goal, the round, and link the pane. |
| After every round | One digest. |
| When the human asks "status" | One digest. |

Digest shape:

```
Needs you
- <project> / <goal> round <n>: <what>, <link>

<project> — <goal title>
- round <n> of <budget>, status <active|waiting|stopped|done>
- last floor: green | red (<check>)
- next: <next action>
- proposals: <path>: <what>, or none
```

Every project gets a block, with one `<project> — <goal title>` block per
goal folder, a waiting, stopped, or done goal included. Post each digest
with `post_note` in one call, then print it in your pane. Send a push
notification for an "at once" item when the human is away from the terminal.
Do not narrate events; report the ones that need the human.

### Proactive, not on request

The human does not ask for a catch-up. Bring the result:

- **A round closes**: the digest in the pane, and one push notification
  under 200 characters that names the outcome and the link: `round 12
  done: WHERE columns per filter · PR #134`. A failed round or a stop
  rule: the same, with the reason.
- **A goal is done** (its completion condition holds and the package is
  committed): run `gh pr ready <N>`, then say so once, with the link,
  and what merging changes for the running daemon. You cannot merge:
  the auto-mode classifier refuses `gh pr merge`. The human merges,
  once per goal.
- **Something needs the human** (`needs-input`, `needs-approval`, a
  `propose`, a decision a crew asked for): a push notification at once,
  then the pane.
- **A day passes with work and no report**: one digest at the day's end.
- **Nothing is running and nothing waits**: say so once, with the
  proposals open, and hold. Do not send a notification for that.

A notification is one line the human acts on; the pane carries the rest.
Never notify for progress inside a round.

### The crew's notes

A crew posts three notes, not one, so you relay a blocker while it is
still cheap:

1. **Plan**, within its first minutes: the files it expects to touch, the
   check it will add, and any assertion it believes is chartered. Read it
   and correct the scope before the work, not after.
2. **Blocker**, when it needs a decision, a permission, or a fact only the
   human has. It stops after this note. Relay it at once.
3. **Done**, under 1900 bytes: the shas, the files, the floor, the
   assertions replaced and why, the choices where the design was silent.

The prompt asks for all three by name. A crew that posts only the last one
has still done the round; note the missing plan in the record's
reflection, because the plan is what catches a wrong charter early.
