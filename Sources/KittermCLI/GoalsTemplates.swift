import Foundation
import KittermDaemon

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

    /// The SHA-256 of `loop` at every version this binary or an earlier one
    /// wrote, newest first, so `kitterm project init --refresh` rewrites a
    /// `LOOP.md` that is still a template and refuses one a human edited.
    /// When `loop` changes, append the hash it had before the change;
    /// `GoalsTemplatesTests` pins that the current one is listed. Seeded
    /// from `git log -- examples/goals/LOOP.md`: `one-rule-one-place`
    /// round 3 (current, the correction: a failed round closes on a red
    /// check; 7f5357e, two corrections per round and `round close
    /// --decision`; a63788e, the round 1 correction: "The floor" reads `gh pr checks`
    /// before `kitterm round close`; 83ea45c, each rule has one home: the
    /// foreman's steps move to the skill, and `kitterm round open` and
    /// `round close` do the round's bookkeeping), `round-commands` round 3 (883a88d, "The round record"
    /// names the `- Foreman:` line and the marker `kitterm round close`
    /// writes), round 2 (5a0fa75, "Parsed
    /// shapes" names what `kitterm round open` writes),
    /// `foreman-scope` round 3 (d9f708a, "One foreman for every scope", the
    /// `scope` label, the Start and Upkeep steps), chore `base-branch`
    /// (a7aae80, "The pull request" and "The floor" name the base branch,
    /// not `main`), `foreman-flow` round 3 (8df2ab6, "The floor"),
    /// round 1 (e78e93d, "The pull request"),
    /// `human-file-edits` (#166), `loop-and-skill` round 2 (092652221ab1),
    /// round 1 (a5592bd), 7f30556 (#139), 41b6a76 (#113) and ac20d04 (#111).
    static let loopHistory: [String] = [
        "a91c6753da227833b6e37ee69bc1fdbda5699d614dd344fa1e3e54427302551b",
        "7f5357e67a3e00c1242e68bf545a47130e19423dd60115a106c1d4b817af4bf9",
        "a63788e8fa76c0f120026f71ffa0cba817c0d92ac67f73e42d1e656c71ded55f",
        "83ea45c4d9740d76a7d11e5dc91f429529cb3b1102f1f6061b7226e974283d36",
        "883a88dd7d2cf04b8eee49f6ac58d99424243ecad22abc842345d7f0950e1c08",
        "5a0fa7547956395ad4220fe012a645beb969332605ff710deeafbdf953dd23c6",
        "d9f708a5b8b7e3548fc2f694a6009e4da0ac786af1dcd9be5d63d8f57fc909a7",
        "2caccfb9969d69be4447ee18488230bdfba02cee2c82da4d4278d614a7ce2b82",
        "a7aae8079cf2840429ff900add915e7cdd90ce10aef3e649886a0c195ef76127",
        "8df2ab62963ad262c015a9d98d6d00d89979710f862bd1156ce3807b2f9fcdcd",
        "9c7ae1a8428eea730235feec0a19c1f2589693a4e7ff125dac41ba48cdd22cb1",
        "e78e93da9c9eabc4918f4f8eb1fd2e88afe3bbb6e10cd01622ed17494b3b97f5",
        "27900ae25babc94f383cc3769d77951b9d24413e1c09ffe509403eac6801c909",
        "092652221ab14e27f5bce545447cc6b237dfb8b3ddee95915f5e0f0040b4459c",
        "68a25c51fe74dc68c28c4f906fd6e93fbe8a126b283172cbc46ab0c4e9a9630e",
        "b7ced93af014fa729fbad0f1cdb7fef2d9d5f4a71697be7f3aec7f7446d65d58",
        "34d7ceab34de1916f645df4f4ab28128cd3f4fc0bfa9644428482b78f09fb6b9",
        "d428fec3d6b8f8aca9b92e685e067943824b30039e96c8c0433bb15fec430292",
    ]

    /// Where a project's `LOOP.md` stands against the template: `current`
    /// (the template's own bytes), `behind` (an older shipped version —
    /// `kitterm project init --refresh` would rewrite it), or `edited`
    /// (neither — a refresh refuses it).
    enum LoopState: String {
        case current, behind, edited
    }

    /// Compare a `LOOP.md`'s bytes against the template and `loopHistory`.
    /// `ProjectCommand.refreshLoop` and `ProjectCommand.checkLoop` both call
    /// this, so the rewrite and the check can never disagree. Returns the
    /// state and the SHA-256 of `data`, which a caller that rewrites the
    /// file reports as the version it replaced.
    static func loopState(of data: Data, history: [String] = loopHistory) -> (state: LoopState, hash: String) {
        let hash = TokenStore.hash(String(decoding: data, as: UTF8.self))
        guard data != Data(loop.utf8) else { return (.current, hash) }
        return (history.contains(hash) ? .behind : .edited, hash)
    }

    static let loop = #"""
        # LOOP

        Each rule of the goal loop has one home. This file holds the policy: the
        roles, goal or chore, the pull request, the floor, the authority tiers, the
        parsed shapes, the budget, direction, and the stop rules. The
        `foreman-loop` skill, which `kitterm skills install` writes, holds the
        foreman's procedure. kitterm's manual, `docs/foreman.md` in its
        repository, holds the set-up, the MCP tools, the typed state, and the
        daemon's behaviour on an upgrade and a restart. The other two name a rule
        of this file in one sentence and do not restate it. This file changes when
        the process changes.

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
        nothing else; narrative goes to the records.

        ## Roles

        - **The human** owns rounds. The human writes `goal.md`, `plan.md`, this
          file, and `corpus/`. After each budget the human picks continue,
          redirect, or stop.
        - **The foreman** owns turns inside a round, for every project in its scope.
          One foreman runs per scope, in a kitterm pane named `foreman` with the
          labels `crew:foreman` and `scope:<path>`, on the `foreman-loop` skill and
          the kitterm MCP tools. It
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
        has no folder. It runs on the branch `chore/<slug>` as one crew session
        with one prompt, one pull request, and one file of one line,
        `<knowledge directory>/chores/<ISO date>-<slug>.md`:

        ```
        - <ISO date> · <what, one sentence> · PR #N · <cost line>
        ```

        One file per chore, so two chore pull requests opened on the same day
        merge in either order with no conflict; a shared list that every chore
        appends to makes every second chore a conflict. The `chores/` folder
        holds no `STATE.md`, so the daemon and `kitterm goal list` skip it.

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

        ## The pull request

        Every goal and every chore has one branch and one open pull request,
        open before its crew starts. The human watches the diff while the work
        runs, and the fleet view shows the round and its pull request.

        Every pull request merges into the base branch: the branch `plan.md`
        names, or, when `plan.md` names none, the one
        `git symbolic-ref --short refs/remotes/origin/HEAD` prints
        (`origin/develop`, for example).

        - A goal's branch is `goal/<slug>`. A chore's branch is `chore/<slug>`.
          The branch is cut from `origin/<base>` in a worktree of its own.
        - `kitterm round open` does every step before the crew starts: it cuts
          the branch, commits the queue line, pushes the branch, opens a draft
          pull request with `gh pr create --draft --base <base>` when none is
          open, and spawns the crew session. kitterm's `docs/control-plane.md`
          gives each step.
        - The pull request's number goes in three places: on the queue line in
          `STATE.md`, as `, PR #N.` at the end of the item's first line; on the
          crew session, as the label `pr:<N>`; and in the round record's
          `Result:`, when `kitterm round close` writes the record. No record
          needs a later commit to name its pull request.
        - A goal keeps its one branch for all its rounds, and an open pull
          request for as many rounds as the human leaves it open. Each round's
          record and `STATE.md` commit land on that branch. The human can merge
          the pull request before the goal is done; the next `kitterm round open`
          then opens a new one. kitterm's own records show both: its goal
          `code-editor` used 6 pull requests and `sessions-workflow` 4. When the
          goal is done, the foreman runs `gh pr ready <N>`, and the human merges.
        - A crew pushes to its branch after each commit. A crew never pushes to
          the base branch, never force-pushes, and never merges.
        - After any merge to the base branch, the foreman rebases every open goal
          or chore branch onto `origin/<base>` and pushes each one with
          `--force-with-lease`. Only the foreman force-pushes. Two green pull
          requests made the base branch red on 2026-09-28: one added a CI check,
          the other added a file the check rejects. The rebase makes each pull
          request's CI meet every new check before the pull request merges.
        - When the human merges a pull request, the foreman deletes its branch
          with `git push origin --delete <branch>`, then removes the worktree with
          `git worktree remove` and the local branch with `git branch -D`. A
          merged branch left on the remote reads as open work.
        - The foreman cannot merge: the auto-mode classifier refuses
          `gh pr merge`. The human merges each pull request, after the foreman
          has committed the package and marked the pull request ready.

        ## The floor

        `plan.md` names the floor's checks. From the round the pull request opens,
        its CI run is part of the floor: a green run already proves the base sha.

        - Before a round, the foreman checks whether the world already proved the
          base sha: a green run on the base branch's own checks
          (`gh run list --workflow ci.yml --branch <base>`; a project whose
          workflow file has another name uses that one), or a green run on the
          goal's pull request at the base (`gh pr checks <N>`). Either green
          skips the floor, and the foreman writes which run it relied on in the
          round record's `Floor` "before" line. Neither green: the foreman runs
          the floor as before the round.
        - The crew runs `<the checks plan.md marks as its own>` once, after its
          change, then pushes. A check `plan.md` marks as proved by the pull
          request's continuous integration is not the crew's to run again;
          `<a check that runs only for a narrow class of change>` runs only when
          the round touches the surface it measures, as `plan.md`'s floor says.
        - After the crew, the foreman does not rerun a check the crew already ran
          or a check the pull request's CI already proves. It reads the diff and
          sorts the paths into the Authority table below, then reads
          `gh pr checks <N>` on the crew's head sha. Green: it runs
          `kitterm round close`, replaces the record's markers, then runs
          `kitterm round close --commit`. Red: the check is the round's gap, a
          correction goes to the crew ("Budget"), and the round closes only green
          or failed: `--decision failed` commits on a red check.

        ## Authority

        | Tier | Paths | Rule |
        |---|---|---|
        | Free | `<source directories>`, `<test directory>` new files, `<docs directory>` except this package, `AGENTS.md`, `<examples directory>`, `STATE.md`, `rounds/`, `facts.md` (append) | The crew and the foreman change these inside a round. |
        | Propose | `plan.md`, this file, `<decision records directory>`, `<CI workflow directory>`, `<package manifests>`, `<benchmark directory>` | The foreman writes the proposal in the round record with decision `propose`. The human edits the file. |
        | Frozen | `goal.md`, `corpus/`, an existing test file, an existing bench scenario and its gate, `<lockfiles>` | Nobody changes these inside a round, except a Chartered assertion. A repair that needs one stops the loop. |
        | Chartered | an assertion in an existing test file that pins a text, a count, or a layout this round must change | The crew replaces the assertion inside the round and keeps its intent. The foreman records the replacement. |

        A path under Frozen in the round's diff fails the round.
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
          sections, and the skill's "Schedule" orders the goals by `Updated`.
        - `kitterm round close` writes `- Round:`, `- Rounds total:` and
          `- Updated:` when a round ends, and files the item by `--decision`:
          under `## Done`, under `## Failures`, or left under `## Queue` for
          `propose`; the foreman does not raise `- Round:`
          when a round opens. The foreman writes `- Status:` and `- Last floor:`,
          and resets `- Round:` at a direction check ("Direction").
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
          whole first line. `kitterm round open` writes the line:
          the text before its first comma, less a final `.`, then `, round R.`
          before the pull request opens and `, round R, PR #N.` after. Prose under a heading (`None.`) names
          no task. A slug in two sections keeps the state a reader needs most,
          `failed` over `pending` over `done`, at its first position. The fleet
          view lists every task that is not done and the first two done ones
          under the goal.

        ### The round record

        `kitterm round close` writes `<slug>/rounds/NNN.md` with this shape.
        Three-digit number, one file per round, never rewritten after the round
        ends. `Result:` names the pull request `kitterm round open` opened before
        the round, `PR #N`, from the `pr:` label ("The pull request"), so the
        record names it when it is written.

        ```markdown
        # Round NNN: <queue item>

        - Goal: <slug>
        - Started: <ISO date>  Ended: <ISO date>
        - Sessions: <id>, <id>   Archives: <id>
        - Base: <git sha>   Result: <git sha or PR #>
        - Cost: $D · Nk in (C% cached) · Nk out · Hh Mm
        - Foreman: ~$D · Nk in (C% cached) · Nk out

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

        `kitterm round close` archives every session the record's `Sessions:`
        line names and writes one `- Cost:` line per session, in that order,
        under the record's header, with the reader of
        `kitterm archive cost <id> --line`. That command reads the archive's
        transcript under `~/.kitterm` with no daemon and prints the line above,
        or `- Cost: none recorded (<reason>)`; `--json` prints the bill as
        `GET /api/archives/<id>/cost` answers it.

        The record's `- Foreman:` line, after the `- Cost:` lines, is the
        estimate of the foreman's own turns between `Started` and `Ended`, from
        the foreman's transcript, priced by `ModelPricing`: `- Foreman: ~$D · Nk
        in (C% cached) · Nk out`, or `- Foreman: none recorded (<reason>)`. A
        model `ModelPricing` does not know adds ` · unpriced <model>` to the
        line: its tokens count and its dollars do not. The line does not start
        with `- Cost:`, so neither parser below counts it. Each of the six
        sections holds the marker line `[foreman writes this]`, and `Floor`
        holds two, `before:` and `after:`; the foreman replaces each, and
        `kitterm round close --commit` refuses while one remains.

        Two parsers read the record:

        - `KnowledgeSummary.roundRecord`, for `rounds` of
          `GET /api/projects/<id>/knowledge` and the fleet view: the file name
          `NNN.md` is the round number; the queue item is what follows
          `# Round NNN:`; the day is the `YYYY-MM-DD` the `- Started:` line begins
          with, and a record with no day is in no range of the fleet view; the cost
          and the duration sum the header's `- Cost:` lines, the lines before the
          first `## ` heading, a `none recorded` line skipped
          (`KnowledgeSummary.costLine`); the pull request is the first `PR #N` on
          a `- Result:` bullet, else the first `PR #N` after `Result:` on the
          `- Base:` line; the bullet wins when a record carries both; a result
          given as a sha, on either shape, names none; a correction is a
          `## Correction` section whose text, after list marks and spaces, is not
          empty and does not start with "None" in any case
          (`KnowledgeSummary.isCorrection`).
        - `kitterm goal cost` (`GoalLedger`): the ids on the `- Sessions:` line
          and after `Archives:`; the sha on the `- Base:` line; the result sha
          and the `PR #N` by the same rule, from a `- Result:` bullet, else
          after `Result:` on the `- Base:` line; the `- Cost:` line at the same
          position as each session the `Sessions:` line names, read when the
          session's archived transcript holds no bill; the first `N new` under
          `## Floor` as the tests added; the first word under `## Decision` as
          the decision.

        ### Labels

        | Key | Value | Set by |
        |---|---|---|
        | `crew` | goal slug; `foreman` for the foreman's own pane; `helper` for a session a crew spawns inside a round | foreman, or the crew for a helper |
        | `scope` | the scope directory, an absolute path | foreman, on its own pane |
        | `goal` | goal slug | foreman |
        | `round` | round number | foreman |
        | `task` | queue item slug | foreman |
        | `pr` | pull request number, the one the queue line names | foreman |
        | `resumed-from` | archive id, or the id the pane held before an epoch change | foreman, on a respawn |

        `SessionLabels` names the keys the loop reserves and passes them through
        on every session row; the fleet view joins a live session to its goal
        folder by `goal:<slug>` and marks the queue item `[working]` by
        `task:<slug>` under it. A session the crew spawns inside the round
        carries `crew:helper` with the round's `goal:` and `round:` labels, and
        the crew ends it.

        `kitterm round open` spawns the crew session with five labels:
        `crew:<slug>`, `goal:<slug>`, `round:<R>`, `task:<item>` and `pr:<N>`. A
        chore's session carries `crew:<slug>`, `task:<slug>` and `pr:<N>`.

        ## Budget

        - Three rounds per direction check. `STATE.md` counts them.
        - Two corrections per round, to the round's one session. When the second
          fails, the foreman ends the session and the round ends as failed; the
          next round starts a fresh session with the lesson in its prompt.
        - A round attempt the host machine kills does not spend the budget and
          writes no round record. Note it in `STATE.md` under `Failures` as
          `attempt killed: <ISO date>, <what died>`. Leave the round counter and
          the queue item where they are. Run the round again. A failed round is
          the other case: it spends the budget and it gets a record.
        - One crew session per round, plus review sessions when the round's
          capability touches `<a file where a regression costs the most>`.
        - At most one round per goal at a time, and at most three crew sessions
          live across all projects. A review session and a crew's helper count
          toward the cap of three.
        - Commit after every round. `kitterm round close --commit` commits the
          record and the state on the goal's branch before the foreman reports
          the digest; a new fact in `facts.md` goes in a commit of its own before
          it. A record that sits uncommitted is not written. The command pushes
          the branch after the commit, so the pull request carries the record.

        ## One foreman for every scope

        The foreman keeps no state of its own; it rebuilds its view from the
        repositories and from the daemon.

        A foreman's scope is a directory: the value of its own pane's `scope:<path>`
        label, else its pane's cwd. Its projects are the registered projects whose
        root is the scope or lies under it, plus a project a live session under the
        scope discovers. The foreman reads, schedules, types into, archives, and
        relabels a session only inside its scope; it never acts on a session outside
        it. One foreman runs per scope, not per daemon: another live foreman in a
        different scope is not a conflict. Another live foreman in the same scope,
        or in a scope that holds or sits inside this one, is the conflict: the
        foreman stops and tells the human.

        A round is open while a live session carries `crew:<slug>`; a
        `crew:helper` session does not hold the round open. The foreman's steps
        inside its scope (Start, Upkeep, Scan, Schedule, One round, Monitor,
        Reports) are the skill's.

        ## Direction

        After a goal spends its budget the foreman sets its `Status` to `waiting`,
        reports, and keeps the other goals running. At every direction check the
        human prunes `facts.md` and the goal's open proposals. The human answers
        per goal, and the foreman commits every direction edit on the goal's
        branch:

        - **continue**: the foreman resets `Round: 0 of 3 in this budget (<ordinal>
          budget)`, sets `Status: active`, sets `Updated`, and notes the decision
          in `STATE.md`. The goal is runnable on the next scan.
        - **redirect**: the human edits `goal.md` or `plan.md`, then says continue.
        - **stop**: the foreman sets `Status: stopped`, sets `Updated`, and
          archives or ends the goal's crew sessions. The folder stays where it is.
        - **done**: when the completion condition in `goal.md` holds, the foreman
          sets `Status: done`, sets `Updated` to today, writes the next action as
          `None.` with the way to reopen, and stops scheduling the goal. The
          folder stays; the human can reopen it with `Status: active` and a new
          queue at any time.
        - **new goal**: the human names a slug. The foreman runs
          `kitterm goal new <path> <slug>`, which writes
          `<knowledge directory>/<slug>/` from the template and refuses an
          existing folder, and the human writes `goal.md`, `plan.md`, and the
          corpus before the first round. No round starts while the queue still
          reads `<item>`.

        ## Stop rules

        The foreman stops one goal and tells the human when:

        - the budget is spent;
        - a repair needs a change under Frozen;
        - the floor is red at the start of two rounds in a row;
        - a failure does not reproduce in a fresh session;
        - the crew session reports `exited` with a non-zero code twice;
        - the daemon `epoch` changes and the crew is gone (respawn once, then stop).

        A stopped goal does not stop the foreman. The other goals keep running.

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
        Open it with `kitterm round open <root> <goal slug> --task <item>`, then
        start the crew and send the row as the `foreman-loop` skill says.

        """#
}
