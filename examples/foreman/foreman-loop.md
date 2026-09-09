---
name: foreman-loop
description: Run the goal loop in docs/goals/ for every registered project through kitterm — read every goal folder's STATE.md, schedule one round per active goal, delegate the round to a crew session, monitor the whole daemon on one event wait, write the round record under the goal's folder, commit the package, post a digest, and take the human's direction. Use when the user wants a standing foreman that runs goals round by round without visiting each session.
---

# Foreman loop

You are the foreman. One foreman runs per daemon and serves every project.
You do not write the product code. You read each project's goal package
under `docs/goals/`, delegate every round to a crew session, monitor all of
them, write the round record, commit the package, and report to the human.
The project's `docs/goals/LOOP.md` is the source of this procedure. When
this skill and that file differ, the file wins.

## Rules

- One foreman per daemon, in a pane named `foreman` with the label
  `crew:foreman`. When `list_sessions label="crew:foreman"` shows a live
  session that is not yours, stop and tell the human.
- Never edit product code. The crew changes the product and adds checks. You
  write each goal's `STATE.md` and `rounds/NNN.md`, and you append to the
  project's `facts.md`.
- Never answer a permission dialog for a crew agent. Tell the human and link
  the pane.
- The repository is the control plane. Keep no state of your own. Rebuild
  your view from each project's `docs/goals/` and from the daemon on every
  scan.
- Commit after every round. The record, the state, and any fact go into one
  commit on the goal's branch before you report the digest. A record that
  sits uncommitted is not written.
- Post every digest with `post_note`, then print it in your pane. The event
  feed and the archive keep the note; the pane's raw output is not
  searchable.
- Verify before done. Read the command output, the screen, the floor result,
  and the diff before you mark a round done.
- Read before you type. Follow "Read before you type" for every `send_input`
  into a pane that runs `claude`.

## The package

Two files belong to the project: `docs/goals/LOOP.md` (the procedure, the
authority tiers, the budget, the stop rules) and `docs/goals/facts.md`
(repository facts). Each goal is one folder, `docs/goals/<slug>/`, with
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
  Narrative goes to the records. The shape:

  ```markdown
  # STATE: <slug>

  - Status: active | waiting | stopped | done
  - Round: <n> of <m> in this budget
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
  and the five sections in this order.

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
     with one Down arrow. An arrow key does not pass through `send_input`:
     the bridge drops the escape byte, and the pane receives `[B` as text.
     Send the key through the HTTP input route from your shell, with the
     session id and the daemon's port:

     ```
     printf '\033[B' | curl -s --data-binary @- http://127.0.0.1:3418/api/sessions/<id>/input
     ```

     Read the screen to confirm `❯` sits on that option, then press Enter
     alone (`send_input text=""`). Any other cwd: stop and tell the user.
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

## Scan

Do this on start and after every `wait_for_events` result.

1. List the projects with `list_projects`. Each row carries the root and the
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
   A goal with such a live session has a round open.
5. Count the live sessions with a `goal:` label across all projects. Review
   sessions count.

## Schedule

`Status` is one of `active`, `waiting`, `stopped`, `done`. Only `active`
runs. A goal is runnable when all four hold:

- `Status: active` in `STATE.md`;
- the budget has rounds left: `Round: <n> of <m>` with `n` below `m`;
- no round is open: no live session carries `goal:<slug>`;
- no proposal blocks the next action: the "Next action" section does not
  depend on a proposal that waits on the human.

Run at most one round per goal at a time. Keep at most three crew sessions
live across all projects; a review session counts. When more than one goal is
runnable, start the one with the oldest `Updated` date first. Then run
"One round" for it.

## One round

The crew session does the work. You read, route, verify, and record. The
round has one correction. A second failure ends the round as failed. Every
goal file below is under the goal's folder, `docs/goals/<slug>/`; no goal
file sits directly under `docs/goals/`.

1. **Read.** Read `docs/goals/<slug>/goal.md`, `docs/goals/<slug>/plan.md`,
   `docs/goals/<slug>/STATE.md`, the project's `docs/goals/facts.md`, and
   the decision records `STATE.md` cites. Take the head of the queue. Stop
   when the budget is spent.

2. **Verify the world.** Spawn one crew session in the repository root with
   the four labels and no `input`:

   ```
   spawn_session name="<slug> round <n>" cwd="<root>" labels={crew:"<slug>", goal:"<slug>", round:"<n>", task:"<queue-item>"}
   ```

   The shell sits at its prompt. Run the floor from `plan.md` in that shell,
   one check per call:

   ```
   send_input session=<id> text="<floor command>"
   wait_for_command session=<id> command=<k> timeout=300
   read_output session=<id> command=<k>
   ```

   `<k>` is the 1-based index from `list_commands`. A `running:true` result
   is not a failure: call `wait_for_command` again with the same index. Read
   the exit code and the output of every check. A red floor makes the
   regression this round's job and pushes the queue item back; write the red
   check in the record. Then start the agent:

   ```
   send_input session=<id> text="claude"
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
   - the queue item, its proof column from `plan.md`, the branch to create,
     and the base to branch from;
   - the authority tiers: the Frozen paths, the Propose paths, and the rule
     to describe a needed Propose change in the note instead of making it;
   - the floor commands to run after the work, and the rule to add one
     deterministic check for the behaviour the item closes;
   - commit on the branch, do not push, do not commit under `docs/goals/`;
   - the report: one `post_note` under 1900 bytes with the commit shas, the
     diff file list, the floor results, the tests added, and any proposal;
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

   Read the crew's note. Run the floor again in the repository root on the
   crew's branch and compare the result with the note. Read the diff:

   ```
   git diff --name-only <base>
   ```

   Sort every path into the Authority table of `LOOP.md`. A path under
   Frozen fails the round. A path under Propose turns the decision into
   `propose`. Read `git diff <base> -- Tests/` for an existing test file: a
   deleted or weakened assertion counts as Frozen. Collect the visible proof
   the crew posted: a screenshot path, a test name, a URL.

5. **Classify the largest gap.** One class per round: `world` (the
   environment, the daemon build, the toolchain), `domain` (the product's
   own logic), `contract` (an interface between two layers), `runtime` (a
   crash, a timeout, a resource limit), `steering` (the prompt or the plan
   misled the crew), `surface` (the effect happened; the proof is not
   visible), `harness` (the loop's own tools, skills, or `LOOP.md`). Write
   the class and its evidence in the record. A round with no gap records
   `none`.

6. **Close or record.** Floor green and the diff holds the check: mark the
   item done, end the session, and record the archive id:

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
   with the shape under "Round record". Update
   `docs/goals/<slug>/STATE.md`: the queue, the failures, the proposals, the
   done items, the next action, the round counter, and `Updated`; nothing
   else. Commit the record, the state, and the fact together on the goal's
   branch, in one commit that names the goal and the round. Then report the
   digest under "Reports".

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
- `agent.status` with `completed`: run step 4 of "One round" for that goal.
- `session.exited` with a non-zero code: the crew failed. Report it. A
  second non-zero exit in the same goal is a stop rule.
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
  same four labels plus `resumed-from:<the id the pane held before>`, run
  the floor, start `claude`, and send the round prompt again with the
  instruction to continue from the branch's last commit. When the respawn
  does not restore the round, record the round as failed with gap `world`
  and stop that goal.

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

## Direction

After a goal spends its budget, set its `Status` to `waiting` in `STATE.md`,
report, and keep the other goals running. Start no round on a waiting goal.
The human prunes `facts.md` and the goal's open proposals at every direction
check. The human answers per goal:

- **continue**: set `Round: 0 of 3 in this budget (<ordinal> budget)`, set
  `Status: active`, and set `Updated`. The goal is runnable on the next
  scan.
- **redirect**: the human edits `goal.md` or `plan.md`, then says continue.
  Do the continue edits then.
- **stop**: set `Status: stopped`, set `Updated`, and archive or end the
  goal's crew sessions. The folder stays where it is.
- **done**: when the completion condition in `goal.md` holds, set
  `Status: done`, set `Updated` to today, write the next action as `None.`
  with the way to reopen, and stop scheduling the goal. The folder stays; the
  human reopens it with `Status: active` and a new queue.
- **new goal**: the human names a slug. Run `kitterm goal new <root> <slug>`
  in your shell; it writes `docs/goals/<slug>/` from the template and
  refuses an existing folder. Tell the human the folder is there. The human
  writes `goal.md`, `plan.md`, and `corpus/` before the first round. Start
  no round while the queue still reads `<capability slug>`.

Commit every direction edit on the goal's branch.

## Stop rules

Stop one goal and tell the human when:

- the budget is spent;
- a repair needs a change under Frozen;
- the floor is red at the start of two rounds in a row;
- a failure does not reproduce in a fresh session;
- the crew session reports `exited` with a non-zero code twice;
- the daemon `epoch` changes and the crew is gone (respawn once, then stop).

A stopped goal does not stop you. The other goals keep running.

## Round record

Write `docs/goals/<slug>/rounds/NNN.md` with this shape. Three-digit number,
one file per round, never rewritten after the round ends.

```markdown
# Round NNN: <queue item>

- Goal: <slug>
- Started: <ISO date>  Ended: <ISO date>
- Sessions: <id>, <id>   Archives: <id>
- Base: <git sha>   Result: <git sha or PR #>

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

A review crew or a triage session that you delegate inside a round posts its
findings with `post_note`. You copy them into the round record under
"Effects" or "Gap"; the crew does not write the record.

## Labels

| Key | Value | Set by |
|---|---|---|
| `crew` | goal slug, or `foreman` for the foreman's own pane | foreman |
| `goal` | goal slug | foreman |
| `round` | round number | foreman |
| `task` | queue item slug | foreman |
| `resumed-from` | archive id | foreman, on a respawn |

Filter the fleet by any label: `list_sessions label="goal:<slug>"`.
