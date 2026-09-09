/// The templates `kitterm project init` and `kitterm goal new` write. Each
/// constant is byte for byte the file of the same path under
/// `examples/goals/`; `GoalsTemplatesTests` pins that, so the installed
/// binary carries the templates with no resource bundle.
enum GoalsTemplates {
    /// The project files, written once into the knowledge directory by
    /// `kitterm project init`. Paths are relative to that directory.
    static let project: [(path: String, contents: String)] = [
        ("LOOP.md", loop),
        ("facts.md", facts),
    ]

    /// The goal folder, written by `kitterm goal new` as
    /// `<knowledge>/<slug>/`. Paths are relative to the goal folder. A
    /// `.gitkeep` is empty.
    static let goal: [(path: String, contents: String)] = [
        ("goal.md", goalFile),
        ("plan.md", plan),
        ("STATE.md", state),
        ("corpus/.gitkeep", ""),
        ("rounds/.gitkeep", ""),
    ]

    /// Every embedded file with its path under `examples/goals/`: the
    /// project files, then the goal folder under `goal/`.
    static let files: [(path: String, contents: String)] =
        project + goal.map { (path: "goal/" + $0.path, contents: $0.contents) }

    /// The placeholder `kitterm goal new` replaces in `STATE.md`.
    static let slugPlaceholder = "<goal slug>"

    static let loop = #"""
        # LOOP

        The procedure, the authority, the budget, and the stop rules for every goal
        loop in this repository. This file changes when the process changes.
        `STATE.md` changes after every round.

        The repository is the control plane. The package is small on purpose.
        Two files belong to the project: this file and `facts.md`. Each goal is
        one folder under `<knowledge directory>/<slug>/` with `goal.md`, `plan.md`,
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

        ## Authority

        | Tier | Paths | Rule |
        |---|---|---|
        | Free | `<source directories>`, `<test directory>` new files, `<docs directory>` except this package, `AGENTS.md`, `<examples directory>`, `STATE.md`, `rounds/`, `facts.md` (append) | The crew and the foreman change these inside a round. |
        | Propose | `plan.md`, this file, `<decision records directory>`, `<CI workflow directory>`, `<package manifests>`, `<benchmark directory>` | The foreman writes the proposal in the round record with decision `propose`. The human edits the file. |
        | Frozen | `goal.md`, `corpus/`, an existing test file, an existing bench scenario and its gate, `<lockfiles>` | Nobody changes these inside a round. A repair that needs one stops the loop. |

        Before the foreman accepts a round it runs `git diff --name-only <base>` in
        the crew session and reads the output. A path under Frozen fails the round.
        A path under Propose turns the round's decision into `propose`. A deleted or
        weakened assertion in an existing test counts as a Frozen change.

        The loop can change the product. It cannot change the evidence that decides
        whether the product improved.

        ## Budget

        - Three rounds per direction check. `STATE.md` counts them.
        - One correction per round. A second failure ends the round as failed.
        - One crew session per round, plus review sessions when the round's
          capability touches `<a file where a regression costs the most>`.

        ## One round

        1. **Read.** Read `goal.md`, `facts.md`, `plan.md`, `STATE.md`, and the
           decisions `STATE.md` cites. Take the head of the queue. Stop when the
           budget is spent.
        2. **Verify the world.** Spawn one crew session in the repository root with
           labels `crew:<goal>`, `goal:<slug>`, `round:<n>`, `task:<queue-item>`,
           and no input. Run the floor from `plan.md` in the shell with
           `send_input` and `wait_for_command`. A red floor makes the regression
           this round's job and pushes the queue item back. Then send `claude` and
           read the screen.
        3. **Send one request.** Type the round prompt in one `send_input`: the
           queue item, its proof from `plan.md`, the facts that apply, the frozen
           and propose paths, the corpus request it serves, and the rule to add a
           deterministic check. From here the foreman loop applies: read before you
           type, wait on `wait_for_events`, route `needs-input` and `needs-approval`
           to the human, never answer for them.
        4. **Collect.** On `completed`, read the last command output and the screen.
           Run the floor again. Read the diff. Collect the visible proof the crew
           posted with `post_note`: a screenshot path, a test name, a URL.
        5. **Classify the largest gap.** One class per round:
           - **world**: the environment, the build, the toolchain.
           - **domain**: the product's own logic.
           - **contract**: an interface between two layers (route, protocol, type).
           - **runtime**: a crash, a timeout, a resource limit.
           - **steering**: the prompt or the plan misled the crew.
           - **surface**: the effect happened; the proof is not visible.
           - **harness**: the loop's own tools, skills, or this file.
           Write the class and its evidence in the round record. A round with no
           gap records `none`.
        6. **Close or record.** Floor green and the diff holds the check: mark the
           item done, archive the crew session, record the archive id. Otherwise
           record the gap, send one correction, and count it inside this round.
        7. **Reflect.** Answer one question in the record: what cost time that a
           rule or a check could prevent? Append a fact to `facts.md`. Propose a
           rule change to this file when the answer is a procedure.
        8. **Update `STATE.md`.** Queue, failures, next action, round counter,
           budget left.

        ## One foreman for every project

        The foreman keeps no state of its own. The repositories are the control
        plane; the foreman rebuilds its view from them and from the daemon.

        1. **Scan.** On start, and after every event batch, list the projects with
           `list_projects`. For each project read every
           `<knowledge directory>/<slug>/STATE.md`. A project with no goal folder
           is reported once as "no goal" and skipped.
           The folder name is the goal's slug; the `goal:` label carries it. Match
           a live session to its goal by the `goal:` and `round:` labels, never by
           id.
        2. **Schedule.** A goal is runnable when its `Status` is `active`, its
           budget has rounds left, no round is open, and no proposal blocks the next
           action. `Status` is one of `active`, `waiting`, `stopped`, `done`; only
           `active` runs. Run at most one round per goal and at most three crew sessions
           across all projects. Start the runnable goal with the oldest `Updated`
           date first.
        3. **Delegate.** Run "One round" for that goal. The crew session does the
           work. The foreman reads, routes, verifies, and records.
        4. **Monitor.** Hold one `wait_for_events` for the whole daemon. On each
           scan compare `heldSince` with now: archive a crew session that sits at an
           empty prompt one hour past `completed`. Respawn a crew once after an
           `epoch` change; record the open round as failed with gap `world` when the
           respawn does not restore it.
        5. **Report.** See "Reports".

        ## Reports

        The foreman reports in three cases. The shape is the same in each case:
        what needs the human first, then one block per project.

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

        Send a push notification for an "at once" item when the human is away from
        the terminal. Do not narrate events; report the ones that need the human.

        ## Direction

        After a goal spends its budget the foreman sets its `Status` to `waiting`,
        reports, and keeps the other goals running. At every direction check the
        human prunes `facts.md` and the goal's open proposals. The human answers
        per goal:

        - **continue**: the foreman resets `Round: 0 of 3 in this budget (<ordinal>
          budget)`, sets `Status: active`, and notes the decision in `STATE.md`.
        - **redirect**: the human edits `goal.md` or `plan.md`, then says continue.
        - **stop**: the foreman sets `Status: stopped` and archives or ends the
          goal's crew sessions. The folder stays where it is.
        - **done**: when the completion condition in `goal.md` holds, the foreman
          sets `Status: done`, notes the date, and stops scheduling the goal. The
          folder stays; the human can reopen it with `Status: active` and a new
          queue at any time.
        - **new goal**: the human names a slug. The foreman creates
          `<knowledge directory>/<slug>/` from the template
          (`kitterm goal new <path> <slug>`), and the human writes `goal.md`,
          `plan.md`, and the corpus before the first round.

        ## Stop rules

        The foreman stops one goal and tells the human when:

        - the budget is spent;
        - a repair needs a change under Frozen;
        - the floor is red at the start of two rounds in a row;
        - a failure does not reproduce in a fresh session;
        - the crew session reports `exited` with a non-zero code twice;
        - the daemon `epoch` changes and the crew is gone (respawn once, then stop).

        A stopped goal does not stop the foreman. The other goals keep running.

        ## Round record

        Write `<slug>/rounds/NNN.md` with this shape. Three-digit number, one file per
        round, never rewritten after the round ends.

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

        ## Labels

        | Key | Value | Set by |
        |---|---|---|
        | `crew` | goal slug, or `foreman` for the foreman's own pane | foreman |
        | `goal` | goal slug | foreman |
        | `round` | round number | foreman |
        | `task` | queue item slug | foreman |
        | `resumed-from` | archive id | foreman, on a respawn |

        """#

    static let facts = #"""
        # Facts

        Repository facts that a later round must not rediscover: measured
        behaviour of the toolchain, the build, the product, and the loop. One
        bullet per fact, newest first inside its topic, each with its date and
        source in parentheses. A goal-local finding stays in that goal's round
        record. A foreman appends; the human prunes at every direction check. A
        fact that becomes a rule moves to `LOOP.md`; one that becomes a design
        decision moves to `<decision records directory>`.

        ## Toolchain

        - <The package manager, the lockfile, and the command that must not run.
          (<ISO date>, <source: round n, code survey, or session>)>
        - <The test command and the platform it runs on. (<ISO date>, <source>)>
        - <A flaky check and how to tell a flake from a regression. (<ISO date>,
          <source>)>

        ## <Topic>

        - <One fact: what is true, where it is measured or decided, what it
          costs. (<ISO date>, <source>)>

        """#

    static let goalFile = #"""
        # Goal: <one line that names the outcome>

        ## Objective

        <What a human sees when the goal is done. Two to six sentences. Name the
        actor, the surface, and the result. Do not list the steps; `plan.md` holds
        them.>

        ## Exclusions

        - <One thing this goal does not do.>
        - <One thing this goal does not do.>

        ## Completion condition

        All <n> hold on a build from `<main branch>`:

        1. <An observable check: the surface, the action, and the value it shows.>
        2. <An observable check.>

        The floor (<the floor checks from `plan.md`, in one line>) is green at
        every step.

        """#

    static let plan = #"""
        # Plan

        The initial floor and the expected capability order for the goal in
        `goal.md`. A human owns this file. A foreman proposes a change to it in a
        round record; it does not edit it.

        ## The floor

        The floor holds earned behaviour. It starts green and must stay green. A red
        floor makes the regression the next round's job.

        | Check | Command | Pass condition |
        |---|---|---|
        | <Unit tests> | `<test command>` | exit 0 |
        | <Build> | `<build command>` | exit 0 |
        | <Performance check> | `<bench command>` | <metric> under <limit> |

        Each round adds at least one deterministic check for the behaviour it
        closes. A check that exists is frozen (see `LOOP.md`).

        ## Capability order

        <n> capabilities. Each ships as one PR. Each names the check that proves it.

        | # | Capability | Proof |
        |---|---|---|
        | 1 | **<Name>.** <What ships: the files, the routes, the commands.> | <The test or the corpus request that proves it.> |
        | 2 | **<Name>.** <What ships.> | <Proof.> |

        <The dependencies between capabilities. Name the independent ones too:
        "Capability 2 depends on 1. Capabilities 1 and 3 are independent.">

        """#

    static let state = #"""
        # STATE: <goal slug>

        - Status: active
        - Round: 0 of 3 in this budget (first budget)
        - Rounds total: 0
        - Last floor: green | red (<check>) (<ISO date>, round <n>)
        - Updated: <ISO date>

        ## Queue

        1. `<item>` (capability 1)
        2. `<item>` (capability 2)

        ## Failures

        None.

        ## Proposals waiting on the human

        None.

        ## Done

        None.

        ## Next action

        Round 1: `<item>` from `plan.md` row 1; proof: `<test or screenshot>`.
        Spawn one crew session in the repository root with labels
        `crew:<goal slug>`, `goal:<goal slug>`, `round:1`, `task:<item>`, and no
        input. Run the floor in the shell, start `claude`, and send the row.

        """#
}
