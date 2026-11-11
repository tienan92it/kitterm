import Foundation

/// The reference skills `kitterm skills install` writes into
/// `~/.claude/skills/<name>/SKILL.md`. Each constant is byte for byte the
/// file of the same name under `examples/foreman/`; `ForemanSkillsTests`
/// pins that, so the installed binary carries the skills with no resource
/// bundle. Edit the file, then paste it here.
enum ForemanSkills {
    /// One entry per skill, in install order. `name` is the directory the
    /// skill installs into and the `name:` field of its frontmatter.
    static let files: [(name: String, contents: String)] = [
        ("foreman-loop", foremanLoop),
        ("review-crew", reviewCrew),
        ("triage", triage),
    ]

    /// Files a skill carries beside its `SKILL.md`, by path under the skills
    /// directory. Each is byte for byte the file of the same name under
    /// `examples/foreman/`.
    static let supportFiles: [(path: String, contents: String)] = [
        ("foreman-loop/crew-settings.json", crewSettings),
    ]

    /// Every file `kitterm skills install` writes, in order: each skill's
    /// `SKILL.md`, then each support file.
    static var installed: [(path: String, contents: String)] {
        files.map { ("\($0.name)/SKILL.md", $0.contents) } + supportFiles
    }

    /// The `description:` field of a skill's frontmatter, or an empty string
    /// when the frontmatter has none.
    static func description(of contents: String) -> String {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard lines.first == "---" else { return "" }
        lines = lines.dropFirst()
        for line in lines {
            if line == "---" { break }
            if line.hasPrefix("description:") {
                return line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    static let foremanLoop = #"""
        ---
        name: foreman-loop
        description: Run the goal loop in docs/goals/ for every registered project through kitterm — read every goal folder's STATE.md, schedule one round per active goal, delegate the round to a crew session, run `kitterm foreman watch` in the background and yield the turn until woken, write the round record under the goal's folder, commit the package, post a digest, and take the human's direction. Use when the user wants a standing foreman that runs goals round by round without visiting each session.
        ---

        # Foreman loop

        You are the foreman. One foreman runs per scope and serves every project in
        it. You do not write the product code. This skill holds your procedure,
        step by step. Each project's `docs/goals/LOOP.md` holds the policy, from
        the roles to the stop rules. kitterm's `docs/foreman.md` holds the set-up,
        the MCP tools, the typed state, and the daemon's behaviour on an upgrade
        and a restart. A step below names a rule of either file in one sentence
        and does not restate it.

        ## Rules

        - One foreman per scope, in a pane named `foreman` with the labels
          `crew:foreman` and `scope:<path>`. Your scope is the value of that label,
          else your pane's cwd. Act only inside it, and stop on the conflict
          `LOOP.md`, "One foreman for every scope", names.
        - Never edit product code, and never answer a permission dialog for a crew
          agent (`LOOP.md`, "Roles"). Tell the human and link the pane.
        - Keep no state of your own. Rebuild your view from each project's
          `docs/goals/` and from the daemon on every scan.
        - Post every digest with `post_note` in one call, then print it in your
          pane. The event
          feed and the archive keep the note; the pane's raw output is not
          searchable.
        - Verify before done: read the command output, the screen, the floor
          result and the diff before you mark a round done.
        - Every message the foreman types into a crew pane starts with `FOREMAN:`
          and carries one instruction. The crew treats `FOREMAN:` text as the
          foreman's word.

        ## The package

        Read `<knowledge>/LOOP.md` at the start of every scan and follow it: its
        "Parsed shapes" section is the contract you write into, and where this
        skill and that file differ, the file wins. `LOOP.md` gives the package's
        layout and what `facts.md` and `STATE.md` each hold; `facts.md`'s header
        gives a fact's shape. Append under the topic that fits; add a topic only
        when none fits. A registered project may name another
        knowledge directory in place of `docs/goals`; `list_projects` reports it.

        ## Chores

        `LOOP.md`, "Goal or chore", is the test of what is a goal, and gives a
        chore's one file, `docs/goals/chores/<ISO date>-<slug>.md`. Open a chore
        with `kitterm round open <root> <slug> --task <slug> --chore`: it cuts
        `chore/<slug>`, opens the draft pull request, and spawns the crew session
        with `crew:<slug>`, `task:<slug>` and `pr:<N>`. Close it with
        `kitterm round close <root> <slug> --chore`, which writes the file with
        the line `kitterm archive cost <id> --line` prints for the archived crew
        session. Replace the file's marker, then run the close again with
        `--commit` once `gh pr checks <N>` is green on the head.

        ## Task list

        Keep a Claude Code task list beside the package, with `TaskCreate`,
        `TaskUpdate`, and `TaskList` (load them with `ToolSearch` when they sit
        deferred). `STATE.md` and the chore files stay the record; the task list
        is a view.

        - One task per open round or chore, subject `<project> / <slug> round
          <n>: <queue item> · PR #N` (a chore: `<project> / chore <slug>: <what>
          · PR #N`), with an `activeForm`.
        - One task per item that waits on the human: `Merge PR #N`,
          `Decide: <proposal>`, `Answer: <crew blocker>`.
        - Set a task `in_progress` when its crew starts, and `completed` when the
          round record or the chore line is pushed, or when the human merges or
          decides. A killed attempt keeps its task `in_progress`. Never mark a
          task `completed` while the floor is red.

        ## Read before you type

        Do this before every `send_input` into a pane that runs an interactive agent.

        1. Call `screen_state` first. On `prompt-empty`, type the message now and
           skip to step 4. On `trust-dialog`, `permission-dialog`, `working`, or
           `waiting-on-own-job`, act as step 3 says, and call `read_screen` before
           any keystroke into a dialog. On `unknown`, `agent-exited`, or anything
           else, call `read_screen`, find the row the cursor is on, and follow the
           rest of these steps from step 2.
        2. Type only when the prompt is at the cursor and the input box is empty: the
           cursor row reads `❯` and the cursor sits right after it. A `{dim}…{/dim}`
           run at the cursor is a placeholder. Treat it as empty. Never treat it as
           text, and never press Enter on it.
        3. When the screen shows something else, do not type the message. Act on what
           the screen shows:
           - Trust dialog — "Is this a project you created or one you trust?" with
             the options `No, exit` and `Yes, I trust this folder`. When the cwd is
             the repo the user named, move the mark to `Yes, I trust this folder`
             with `send_input keys=["down"]`. Read the screen to confirm `❯` sits
             on that option, then press Enter with `send_input keys=["enter"]`.
             Any other cwd: stop and tell the user.
           - Permission dialog — "Do you want to proceed?" or a numbered choice with
             a `Yes` and a `No`. Never answer it. Tell the user and link the pane.
           - In-progress turn — a spinner line with "esc to interrupt", or a `⏺`
             tool call above an empty prompt that has not returned. Wait. Call
             `wait_for_events` until the session reports `completed` or
             `needs-input`, then read the screen again.
        4. Send the message with `send_input`. Send one dialog keystroke per call, and
           read the screen between keystrokes.
           A `cooked reader` error typed nothing (`docs/foreman.md`, "The loop"): go
           back to step 1. Set `force:true`
           only for a shell that reads lines under 1 KiB as they come.
        5. Call `read_screen` again. Confirm the text you typed now appears above the
           input box as `❯ <your text>` and the box is empty again. When the text
           still sits in the box, press Enter alone (`send_input text=""`) and read
           once more.

        ## Start

        Do this once, before "Scan".

        1. Read your pane's labels for your scope ("Rules").
        2. Run `kitterm foreman catch-up`, with `--scope <path>` when your pane
           carries a `scope:` label. It prints the predecessor foreman in your
           scope, the goals not done, the live crews, and the worktrees.
        3. When the catch-up shows the conflict of `LOOP.md`, "One foreman for
           every scope", stop and tell the human; do not act.
        4. Read the predecessor's note and the last message of its transcript, for
           what the human told it. Adopt its open pull requests and its live crews
           by their labels.
        5. Archive the predecessor's pane only when the human says so, and only
           when it sits inside your scope.
        6. Call `TaskList`, then rebuild your task list from the goals not done,
           the live crews, and the open pull requests ("Task list"), so no task
           is created twice.

        ## Upkeep

        Do this at start, and again whenever `kitterm skills install` changes this
        skill.

        Run `kitterm round guard --check`. Any answer but `kitterm round guard:
        ready` means the crew hook cannot run and refuses every `Bash` call of a
        crew: tell the human before you open a round.

        For every project in your scope, run
        `kitterm project init --refresh --check <root>`:

        - `current`: do nothing.
        - `behind`: run a chore (`LOOP.md`, "Goal or chore") on the branch
          `chore/refresh-loop`, one crew session that runs
          `kitterm project init --refresh <root>`, with its own draft pull request.
        - `edited`: open a draft pull request on the project's base branch that
          brings the new template sections of `LOOP.md` into the project's own
          `LOOP.md`, keeping the project's own lines. The human's merge is the
          Propose-tier approval (`LOOP.md`, "Authority"); you do not edit the
          file yourself.

        ## Scan

        Do this on start and after every `kitterm foreman watch` wake ("Monitor").

        1. List the projects with `list_projects` and keep the ones whose root is
           your scope or lies under it. When the tool is absent, use the project paths the
           human gave you.
        2. For each project read `<root>/<knowledge>/LOOP.md` and
           `<root>/<knowledge>/facts.md`: the policy the project runs under, and
           the facts every round of it must respect. A project with
           no `LOOP.md`: report "no package" once, then skip it on every later scan.
        3. For each project list the folders under `<root>/<knowledge>/`. A folder
           with a `STATE.md` is a goal, and the folder name is its slug. Read every
           `<root>/<knowledge>/<slug>/STATE.md`. Take `Status`, `Round: <n> of <m>`,
           `Updated`, the "Next action" section, and the proposals that wait on the
           human. A project with no goal folder: report "no goal" once, then skip it
           on every later scan.
        4. Call `list_sessions`. A session belongs to a goal when its labels carry
           `goal:<slug>` and `round:<n>`. Never match a session to a goal by its id.
           The round's own session is the one with `crew:<slug>`; a `crew:helper`
           session beside it is a fixture the crew made. `LOOP.md`, "One foreman
           for every scope", says when a round is open.
        5. Count the live sessions with a `goal:` label across all projects, for
           the cap of three in `LOOP.md`, "Budget".

        ## Schedule

        A goal is runnable when all five hold:

        - `Status: active` in `STATE.md`;
        - the budget has rounds left: `Round: <n> of <m>` with `n` below `m`;
        - no round is open: no live session carries `crew:<slug>`;
        - no proposal blocks the next action: the "Next action" section does not
          depend on a proposal that waits on the human;
        - no open round's queue item or `plan.md` row names a file that this
          goal's head item or its row names.

        Keep to the caps of `LOOP.md`, "Budget"; Scan step 5 counts the sessions.
        When more than one goal is runnable, start the one with the oldest
        `Updated` date first. Then run "One round" for it.

        ## One round

        The crew session does the work. You read, route, verify, and record.
        `LOOP.md`, "Budget", gives the correction cap and the killed attempt.
        Every goal file below is under the goal's folder, `docs/goals/<slug>/`;
        no goal file sits directly under `docs/goals/`.

        1. **Read.** Read `docs/goals/<slug>/goal.md`, `docs/goals/<slug>/plan.md`,
           `docs/goals/<slug>/STATE.md`, the project's `docs/goals/facts.md`, and
           the decision records `STATE.md` cites. Take the head of the queue.

        2. **Open the round, then verify the world.** Run one command in your
           shell:

           ```
           kitterm round open <root> <slug> --task <queue-item>
           ```

           It does every step `LOOP.md`, "The pull request", puts before the
           crew, up to one crew session in the worktree of `goal/<slug>` with the
           five labels and no input, and prints the `session`, `worktree`, `pr`,
           `round` and `base`. A failure names its step; run the command again and
           it continues from that step. Do not do its steps by hand.

           Create its task ("Task list"), `activeForm` "Running round <n> of
           <slug>", status `in_progress`.

           The shell sits at its prompt. Check whether the world already proved the
           base sha before you run the floor (`LOOP.md`, "The floor", names the two
           runs that prove it). Either green skips the floor; write which run you
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
           below picks for the task, and the crew settings
           (`docs/control-plane.md`):

           ```
           send_input session=<id> text="claude --model <id> --settings ~/.claude/skills/foreman-loop/crew-settings.json"
           ```

           Run "Read before you type".

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
           - the sections of `LOOP.md` the crew follows: "Authority" (describe a
             needed Propose change in the note instead of making it) and "The
             floor" (the crew's own checks once, then push), and the rule to add
             one deterministic check for the behaviour the item closes;
           - commit on the branch and push it after each commit, so the human
             watches the diff on the pull request; never push to the base branch,
             never force-push, never merge; do not commit under `docs/goals/`;
           - the report: the prompt asks for the notes of "Crew notes" by name —
             `PLAN`, `PROGRESS` after each push, `BLOCKER` if one comes, `DONE`
             last — each starting `<KIND> <slug> r<n>: <one line>`; a session that
             dies at its last step still leaves its evidence. Each `post_note`
             stays under 1900 bytes;
           - a session the crew spawns inside the round carries `crew:helper` with
             the round's `goal:` and `round:` labels, and the crew ends it;
           - when a decision needs a human, post a `BLOCKER` note and stop
             ("Crew notes").

           Then run step 5 of "Read before you type" and confirm the prompt sits
           above the box. From here on "Monitor" applies.

        4. **Collect.** On `agent.status` with `completed` for the crew session:

           ```
           list_commands session=<id>
           read_output session=<id> command=<last>
           read_screen session=<id>
           ```

           Read the crew's note. Do not rerun a check the crew already ran, or a
           check the pull request's continuous integration already proves
           (`LOOP.md`, "The floor"). Read the diff, `git diff --name-only <base>`
           and `git diff <base> -- Tests/`, and sort it as `LOOP.md`, "Authority",
           says.

           Collect the visible proof the crew posted: a screenshot path, a test
           name, a URL.

           Read `gh pr checks <N>` on the crew's head sha first; do not rerun the
           checks yourself. Green: go on. Red: the check is the round's gap; send
           the correction (step 6) and do not close the round.

        5. **Classify the largest gap.** One class per round: `world` (the
           environment, the daemon build, the toolchain), `domain` (the product's
           own logic), `contract` (an interface between two layers), `runtime` (a
           crash, a timeout, a resource limit), `steering` (the prompt or the plan
           misled the crew), `surface` (the effect happened; the proof is not
           visible), `harness` (the loop's own tools, skills, or `LOOP.md`). Write
           the class and its evidence in the record. A round with no gap records
           `none`.

        6. **Close or correct.** The floor green (step 4) and the diff holds the
           check: the item is done. When the goal's completion condition then
           holds, run "Review before ready" now, while the crew is live. Otherwise
           record the gap, run "Read before you type", send one correction with
           `send_input`, and go back to step 4. When the cap of `LOOP.md`,
           "Budget", fails the round, write the lesson in the record for the next
           round's prompt. `kitterm round close` archives the round's sessions, so
           run it only once the round needs no more correction: the bill exists only once
           `claude` exits, and archiving is what ends it.

        7. **Reflect.** Answer one question in the record: what cost time that a
           rule or a check could prevent? Sort what you learned by the scopes of
           `LOOP.md`: a repository fact goes to `docs/goals/facts.md` with its
           source (`(<ISO date>, round <n>)`); a goal-local finding stays in the
           record. Propose a change to `LOOP.md` in the record
           when the answer is a procedure.

        8. **Write the record and commit.** Run one command in your shell:

           ```
           kitterm round close <root> <slug> --decision done|failed|propose
           ```

           It archives the round's sessions, writes
           `docs/goals/<slug>/rounds/NNN.md` with a marker line in each section,
           and files the item by the decision (`LOOP.md`, "Parsed shapes"). Replace
           every marker line. A review crew or a triage session that you delegate inside
           a round posts its findings with `post_note`. You copy them into the
           round record under "Effects" or "Gap"; the crew does not write the
           record. Update the rest of `docs/goals/<slug>/STATE.md` yourself:
           `Status`, `Last floor`, the failures, the proposals, and the next
           action; nothing else. Commit a new fact in `docs/goals/facts.md` on the
           goal's branch first. Run `kitterm round close <root> <slug> --commit`
           only after `gh pr checks <N>` is green on the crew's head sha (step 4);
           the command refuses until it is, and while a marker line remains
           (`--no-checks` only for a repository with no CI). It commits the goal
           folder and pushes. The push starts a new CI run, and `gh pr ready`
           waits until it is green too. When the goal is done, run `gh pr ready
           <N>`; the human merges. Then report the digest under "Reports".

        ### Review before ready

        Once per goal, before `gh pr ready <N>`, run one review with fresh
        context: a subagent, or one session of the `review-crew` skill, that gets
        `goal.md` and `git diff origin/<base>...HEAD` and nothing else. It finds
        issues, tries to refute each one, and reports only the survivors. Send a
        survivor to the crew as a correction, or to the human as a note. The
        review does not replace the human's read: reported recall is 29 to 57
        percent. In `one-rule-one-place` round 1, one reviewer found in 3 minutes
        three inconsistencies that 1,442 green tests missed.

        ### The model

        Name the model when you start the crew, with `claude --model <id>`. Pick
        by the task, not by habit:

        | Task | Model | Why |
        |---|---|---|
        | Product code with tests; a design to implement; a round that reads a corpus | `claude-fable-5-2` (the default) | the rounds so far: $5–$38 each, floor green |
        | A document, a wording change, a README, a one-file fix with a clear diff | `claude-sonnet-5-5` | the work is reading and writing prose; a smaller model does it at a fraction of the cost |
        | A repair that must hold a whole subsystem in view: a red floor across many files, a migration, a rename across the tree | `claude-opus-5-5[1m]` | the context is the job |
        | A mechanical script: capture screenshots, run a checklist, copy figures into a table | `claude-haiku-5-5` | fast and cheap; no judgment needed |

        `kitterm round close` writes the model in the round record's `Sessions:`
        line and in the chore line, so the cost has a model beside it. When a
        crew on a smaller model asks for a decision the task should not need, or
        fails its floor twice, the next round's fresh session runs on the default.

        ## Monitor

        Once you send the round prompt and confirm it
        landed ("Send one request"), do not hold an event wait inside this turn:
        start `kitterm foreman watch` in the background and end your turn.

        ```
        kitterm foreman watch --session <id> [--session <id> ...] --since <cursor> --epoch <epoch> --quiet-working [--heartbeat <s>]
        ```

        One `--session` per live crew in your scope — the round's own session, and
        any other goal's crew still running. Never name a `crew:helper` session
        ("Scan", step 4). Run it with
        `Bash(run_in_background)`, so the command holds the wait, not your turn.
        Start `cursor` at 0 with no `--epoch` the first run; after every run, carry
        the `next` and `epoch` it printed into the next one — your turn ends
        between runs, so keep the cursor in the pane's scratch note or your own
        notes, not in memory.

        The command exits and the harness wakes you with exactly one of three
        markers on its last line. Read it and act:

        - `{type:"event", event, next, epoch}` — a watched session posted a `note`,
          an `agent.status`, an `approval.pending`, a `command.failed`, or a
          `session.exited`/`removed`. Run "Scan", then act on the event by its
          type:
          - `agent.status` with `needs-input`, or `approval.pending`: report at
            once ("Reports"). Do not act. When the human gives you an answer, run "Read before you type"
            and pass it on with `send_input`.
          - `note`: relay it ("Crew notes"). The round
            record is the durable copy; the event ring drops a note on a daemon
            restart. A `BLOCKER` note, or a new entry under "## Proposals waiting
            on the human", creates its task, `Answer: <crew blocker>` or
            `Decide: <proposal>` ("Task list"); mark it `completed` when the human
            answers or decides.
          - `command.failed`: read `/commands/<index>/output` with `read_output`.
            Report it at once when it is the crew's floor or a command the round
            depends on. Otherwise let the crew handle it; never act for the crew.
          - `agent.status` with `completed`: run step 4 of "One round" for that
            goal.
          - `session.exited` with a non-zero code, or `session.removed`: the crew
            is gone. Report it; a second non-zero exit is a stop rule.
        - `{type:"heartbeat", next, epoch}` — no watched session matched inside the
          window. Run "Scan" and check "Stall" (below).
        - `{type:"epoch-change", epoch, next}` — the feed's cursor was pruned or the
          epoch no longer matches. Treat it exactly as "A result whose epoch
          changed" below.

        `kitterm foreman watch` can also exit non-zero with no marker, when the
        daemon drops the connection mid-poll, as a live upgrade does once
        (`docs/foreman.md`, "When the daemon upgrades in place"). Run the command
        again with the same `--since` and `--epoch` you gave it, since nothing
        advanced, and run "Read before you type" before you send again a text
        that was in flight.

        On every "Scan" — whatever woke you — also:

        - A merge to the base branch, which only the human makes: rebase every
          open goal or chore branch onto `origin/<base>` and push each one with
          `--force-with-lease`. Only you force-push, and only for this
          (`LOOP.md`, "The pull request", gives the reason).
        - A merge of a goal's or a chore's pull request: delete its branch, its
          worktree and its local branch as `LOOP.md`, "The pull request", says,
          and mark the goal's `Merge PR #N` task `completed`.
        - Compare `heldSince` with now for every live crew session. Archive a crew
          session that sits at an empty prompt one hour past `completed`; only you
          end it (`docs/foreman.md`, "The loop", step 5).

        Report after each crew completes, not while it runs ("Reports"). When
        step 8 of "One round" closes the round — the floor
        green, the record written, the package committed, the digest posted —
        delegate the next runnable goal ("Schedule") or stop, per `LOOP.md`,
        "Direction" and "Stop rules". Otherwise run `kitterm foreman watch` again for the
        crews still live, with the cursor and the epoch the last run printed, and
        end your turn again.

        A result whose `epoch` changed: the daemon restarted; do the steps of
        `docs/foreman.md`, "When the daemon restarts". Respawn each open round's crew once with the
        same five labels plus `resumed-from:<the id the pane held before>`, run
        the floor, start `claude`, and send the round prompt again with the
        instruction to continue from the branch's last commit. When the
        respawn does not restore the round, record a killed attempt (`LOOP.md`,
        "Budget") and stop that goal.

        The human's answer at a direction check is an edit to `STATE.md`, which
        `LOOP.md`, "Direction", gives per answer. Make the edit, commit it on the
        goal's branch, and tell the human when a new goal's folder is there.

        ### Stall

        A crew is stalled when all four hold at a wake:

        - its status is `completed` or `needs-input`;
        - it posted no `DONE` or `BLOCKER` note, and no `PLAN` note that waits on
          you, since its last `working` status;
        - its `lastOutputAt` is more than 120 seconds old;
        - the status bar of `read_screen` names no shell and no monitor, as
          `· 1 shell, 1 monitor ·` does (`screen_state` answers
          `waiting-on-own-job` then).

        No `PLAN` note 15 minutes after the round prompt is a stall too.

        Answer a stall in that wake, or end the session. Read the screen. An API
        error, a model limit, a cut turn, or a prompt that waits with no
        question: send one `FOREMAN: continue from <the last step the screen or
        the notes show>` and tell the human in one line. A question: treat it as
        a `BLOCKER`, relay it, and create its `Answer:` task ("Task list"). One
        automatic continue per round. A second stall in the round: tell the
        human, link the pane, and wait for the human's word.

        After a usage limit, Claude Code continues by itself
        (`autoContinueAtUsageLimit`, on by default, three times at most).

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
        goal folder, a waiting, stopped, or done goal included. Do not narrate
        events; report the ones that need the human. Send a push
        notification for an "at once" item when the human is away from the terminal.

        ### Report latency

        - Before any wait longer than two minutes, say in one line what you wait
          for.
        - When a wait or a watcher returns, read its result before any other
          work, and act on a stall or a blocker first.

        ### Proactive, not on request

        Bring the result:

        - **A round closes**: the digest in the pane, and one push notification
          under 200 characters that names the outcome and the link: `round 12
          done: WHERE columns per filter · PR #134`. A failed round or a stop
          rule: the same, with the reason.
        - **A goal is done** (its completion condition holds and the package is
          committed): after `gh pr ready <N>`, say so once, with the link,
          and what merging changes for the running daemon.
        - **A day passes with work and no report**: one digest at the day's end.
        - **Nothing is running and nothing waits**: say so once, with the
          proposals open, and hold. Do not send a notification for that.

        A notification is one line the human acts on; the pane carries the rest.

        ### Crew notes

        A crew posts notes, not a single report, so you relay a blocker or a plan
        while it is still cheap. Every crew note's first line is `<KIND> <slug>
        r<n>: <one line>` (a chore writes `<KIND> <slug>: <one line>`), and
        `KIND` is one of `PLAN`, `PROGRESS`, `BLOCKER`, or `DONE`:

        1. **PLAN**, before the first edit: the files it expects to touch, the
           check it will add, and any assertion it believes is chartered. Read it
           and correct the scope before the work, not after. In a round that sets
           a data model, an interface or a visual design, the prompt tells the
           crew to wait for `FOREMAN: approved` or `FOREMAN: change <what>`
           before code.
        2. **PROGRESS**, one line after each push: the short sha, what changed,
           and the floor's state.
        3. **BLOCKER**, when it needs a decision, a permission, or a fact only
           the human has. This note is the only way a crew asks; it posts the
           note, then stops. Relay it at once.
        4. **DONE**, last, under 1900 bytes: the shas, the files, the floor, the
           assertions replaced and why, the choices where the design was silent.
           When it needs more room, split it: `DONE 1/3`, `DONE 2/3`, `DONE 3/3`,
           each with the same first-line shape.

        Relay the first line of every note to the human word for word, as it
        arrives. A crew that posts only
        `DONE` has still done the round; note the missing `PLAN` in the record's
        reflection, because the plan is what catches a wrong charter early.

        """#

    static let reviewCrew = #"""
        ---
        name: review-crew
        description: Review a chunk of work with a crew of independent review sessions through kitterm, one per dimension (security, accessibility, performance, reuse), then collect and dedupe their findings. Use when the user wants a multi-angle code review of a branch or a diff.
        ---

        # Review crew

        You run an independent review of a chunk of work. You spawn one review session
        per dimension, each blind to the others, then collect their findings.

        ## Read before you type

        Do this before every `send_input` into a pane that runs an interactive agent.

        1. Call `screen_state` first. On `prompt-empty`, type the message now and
           skip to step 4. On `trust-dialog`, `permission-dialog`, `working`, or
           `waiting-on-own-job`, act as step 3 says, and call `read_screen` before
           any keystroke into a dialog. On `unknown`, `agent-exited`, or anything
           else, call `read_screen`, find the row the cursor is on, and follow the
           rest of these steps from step 2.
        2. Type only when the prompt is at the cursor and the input box is empty: the
           cursor row reads `❯` and the cursor sits right after it. A `{dim}…{/dim}`
           run at the cursor is a placeholder. Treat it as empty. Never treat it as
           text, and never press Enter on it.
        3. When the screen shows something else, do not type the message. Act on what
           the screen shows:
           - Trust dialog — "Is this a project you created or one you trust?" with
             the options `No, exit` and `Yes, I trust this folder`. When the cwd is
             the repo the user named, move the mark to `Yes, I trust this folder`
             with `send_input keys=["down"]`. Read the screen to confirm `❯` sits
             on that option, then press Enter with `send_input keys=["enter"]`.
             Any other cwd: stop and tell the user.
           - Permission dialog — "Do you want to proceed?" or a numbered choice with
             a `Yes` and a `No`. Never answer it. Tell the user and link the pane.
           - In-progress turn — a spinner line with "esc to interrupt", or a `⏺`
             tool call above an empty prompt that has not returned. Wait. Call
             `wait_for_events` until the session reports `completed` or
             `needs-input`, then read the screen again.
        4. Send the message with `send_input`. Send one dialog keystroke per call, and
           read the screen between keystrokes.
           A `cooked reader` error typed nothing (`docs/foreman.md`, "The loop"): go
           back to step 1. Set `force:true`
           only for a shell that reads lines under 1 KiB as they come.
        5. Call `read_screen` again. Confirm the text you typed now appears above the
           input box as `❯ <your text>` and the box is empty again. When the text
           still sits in the box, press Enter alone (`send_input text=""`) and read
           once more.

        ## Steps

        1. Pick the dimensions the work needs. Common ones: security, accessibility,
           database and performance, code reuse, test coverage. Do not run all of them
           on every change; choose the ones the diff touches.

        2. Spawn one session per dimension. Give each the same diff and a different
           review criterion:
           `spawn_session name="review-<dimension>" labels={crew:"review", task:"<dimension>"} input="claude\n"`
           Run "Read before you type", then `send_input` the review prompt: the diff
           to read, the one dimension to judge, the instruction to find issues, then
           try to refute each one and keep only the survivors, and the instruction
           to post the survivors with a note whose first line is `REVIEW <slug> r<n>: <blockers>
           blockers, <should-fix> should-fix, <nits> nits` (a chore: `REVIEW
           <slug>: ...`).

        3. Wait for the crew with `wait_for_events since=<cursor> epoch=<epoch>`. Each
           session posts its findings as a `note` and then reports `completed`. A
           changed `epoch` means the daemon restarted and the crew is gone: list the
           sessions again and respawn the missing reviewers. A `daemon.started` with
           `takeover` set to `"true"` in the same `epoch` is an upgrade in place; the
           crew is still there, so keep waiting.

        4. Collect the notes. Dedupe overlapping findings. Rank each from nit to
           blocking.

        5. Give the user one merged, ranked list. Name the session each finding came
           from.

        6. `kill_session` for every review session once you have its findings. A review
           session's job ends when it hands back its review.

        ## Rules

        - The review sessions are independent. Do not let one see another's findings.
        - A review before `gh pr ready` (the `foreman-loop` skill, "Review before
          ready") is one session that gets `goal.md` and the diff against the base,
          and nothing else.
        - You collect and dedupe; you do not add your own findings.
        - A finding is blocking only if it breaks correctness, security, or a shipped
          feature. Everything else is a nit or a suggestion.
        - When a review session carries a `goal:` label, the merged findings also go
          into that round's record, `docs/goals/<slug>/rounds/NNN.md`, under "Effects" or
          "Gap". The foreman writes them there; a review session never edits the
          record. Spawn such a session with the `goal:` and `round:` labels of the
          round it serves.

        """#

    static let triage = #"""
        ---
        name: triage
        description: Triage a bug in its own kitterm session — reproduce it, find the root cause, and confirm the cause before any fix. Use when the user reports a bug and wants it investigated in an isolated session rather than fixed blind.
        ---

        # Bug triage

        You triage one bug in its own session. You reproduce it, you find the cause, and
        you confirm the cause. You do not fix it until the user asks.

        ## Read before you type

        Do this before every `send_input` into a pane that runs an interactive agent.

        1. Call `screen_state` first. On `prompt-empty`, type the message now and
           skip to step 4. On `trust-dialog`, `permission-dialog`, `working`, or
           `waiting-on-own-job`, act as step 3 says, and call `read_screen` before
           any keystroke into a dialog. On `unknown`, `agent-exited`, or anything
           else, call `read_screen`, find the row the cursor is on, and follow the
           rest of these steps from step 2.
        2. Type only when the prompt is at the cursor and the input box is empty: the
           cursor row reads `❯` and the cursor sits right after it. A `{dim}…{/dim}`
           run at the cursor is a placeholder. Treat it as empty. Never treat it as
           text, and never press Enter on it.
        3. When the screen shows something else, do not type the message. Act on what
           the screen shows:
           - Trust dialog — "Is this a project you created or one you trust?" with
             the options `No, exit` and `Yes, I trust this folder`. When the cwd is
             the repo the user named, move the mark to `Yes, I trust this folder`
             with `send_input keys=["down"]`. Read the screen to confirm `❯` sits
             on that option, then press Enter with `send_input keys=["enter"]`.
             Any other cwd: stop and tell the user.
           - Permission dialog — "Do you want to proceed?" or a numbered choice with
             a `Yes` and a `No`. Never answer it. Tell the user and link the pane.
           - In-progress turn — a spinner line with "esc to interrupt", or a `⏺`
             tool call above an empty prompt that has not returned. Wait. Call
             `wait_for_events` until the session reports `completed` or
             `needs-input`, then read the screen again.
        4. Send the message with `send_input`. Send one dialog keystroke per call, and
           read the screen between keystrokes.
           A `cooked reader` error typed nothing (`docs/foreman.md`, "The loop"): go
           back to step 1. Set `force:true`
           only for a shell that reads lines under 1 KiB as they come.
        5. Call `read_screen` again. Confirm the text you typed now appears above the
           input box as `❯ <your text>` and the box is empty again. When the text
           still sits in the box, press Enter alone (`send_input text=""`) and read
           once more.

        ## Steps

        1. Spawn a session for the bug:
           `spawn_session name="triage-<bug>" cwd="<repo>" labels={crew:"triage", task:"<bug>"} input="claude\n"`

        2. Run "Read before you type", then send the triage prompt with `send_input`:
           the bug report, the repo, and the instruction to reproduce first.

        3. Drive the session to reproduce the bug. Run "Read before you type" before
           each `send_input`. Read the pane with `read_screen`; use `wait_for_command`
           then `read_output` only for a shell command the session runs outside
           `claude`. Do not accept a theory that has no reproduction.

        4. Once reproduced, drive the session to find the root cause. Rank the
           candidate causes, test the most likely first, and confirm which one the
           evidence supports.

        5. Post the finding with `post_note`, its first line `TRIAGE <slug>:
           <reproduced|not reproduced>: <one line>`: the reproduction steps, the
           confirmed root cause, and the file and line. Then report it to the user.

        6. Stop. Do not fix the bug. Ask the user whether to fix it, and wait.

        ## Rules

        - Reproduce before you theorize. A cause with no reproduction is a guess.
        - Confirm the cause. Name the evidence — the failing input and the wrong
          output.
        - Add a regression test that fails before any fix, when the user asks for the
          fix.
        - When the triage session carries a `goal:` label, the confirmed root cause
          also goes into that round's record, `docs/goals/<slug>/rounds/NNN.md`, under
          "Gap" with its evidence. The foreman writes it there; the triage session
          never edits the record. Spawn such a session with the `goal:` and
          `round:` labels of the round it serves.

        """#

    /// The settings of a crew session, `examples/foreman/crew-settings.json`:
    /// the deny rules and the `PreToolUse` hook `kitterm round guard`. The
    /// skill starts each crew with `claude --settings <this file>`, so the
    /// rules reach crew sessions only.
    static let crewSettings = #"""
        {
          "permissions": {
            "deny": [
              "Bash(gh pr merge)",
              "Bash(gh pr merge *)",
              "Bash(kitterm start)",
              "Bash(kitterm start *)",
              "Bash(kitterm stop)",
              "Bash(kitterm stop *)",
              "Bash(kitterm restart)",
              "Bash(kitterm restart *)",
              "Edit(//**/.github/workflows/**)",
              "Edit(//**/docs/goals/*/goal.md)",
              "Edit(//**/docs/goals/*/corpus/**)"
            ]
          },
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "kitterm round guard || exit 2"
                  }
                ]
              }
            ]
          }
        }

        """#
}
