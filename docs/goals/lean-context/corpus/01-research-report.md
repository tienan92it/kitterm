<!-- Copied on 2026-11-10 from the foreman's research report. The human
approved all ten changes with the words "all changes". The source
notes stay outside the repository. -->

# Move the foreman's rules into code

The evidence supports the shape of kitterm's foreman/crew loop: one writer per task, an isolated worktree, a written brief, and a human merge. The measured problems lie in crew context, rules kept as prose, hand bookkeeping, and checks that a crew or the foreman can skip. A 178 KB `AGENTS.md` fills about half of each crew's first-turn context; a controlled study finds that such files add about 20% cost. The loop's rules fill about 48,000 words in five documents, and three copies already contradict each other. The ten ranked changes below favour removal and mechanism over new rules; the top four are cheap and have the strongest support. Most external evidence is vendor-reported, so kitterm's own 146 round records are the measure for each change.

## Late-2026 practice agrees on one shape, and kitterm already has it

### The supported core: single writer, fresh context, independent check

Products and controlled studies agree on one design. One agent owns each write path, it starts from a written brief in an isolated workspace, and a separate checker judges the result. A Google Research study of 180 agent configurations measured a 39–70% loss for every multi-agent variant on sequential tasks. Independent parallel agents multiplied errors 17.2 times; a central orchestrator held that to 4.4 times ([Google Research](https://research.google/blog/towards-a-science-of-scaling-agent-systems-when-and-why-agent-systems-work/)). Anthropic says coding has "fewer truly parallelizable tasks than research" ([Anthropic, 2025-06-13](https://www.anthropic.com/engineering/multi-agent-research-system)). Cognition's 2026 update says the case against parallel writers "still hold[s] today" ([Cognition, 2026-04-22](https://cognition.com/blog/multi-agents-working)). Copilot, Codex cloud, Devin and Claude Code all send a task to its own environment and return a pull request for a human to merge ([GitHub changelog](https://github.blog/changelog/2025-09-25-copilot-coding-agent-is-now-generally-available/)).

### The ideas with the strongest support

The table sorts the core ideas by the strength of their evidence. "Strong" means a controlled measurement; "vendor" means a maker's report on its own product; "thin" means opinion or one anecdote.

| Idea | Evidence | Strength | kitterm today |
|---|---|---|---|
| One writer per task; parallel only for read, review, research | Google 39–70% sequential loss; Claude Code docs: "for sequential tasks … a single session or subagents are more effective" ([docs](https://code.claude.com/docs/en/agent-teams)) | Strong | Yes: one crew per goal round |
| An oracle the agent cannot edit | Human-written tests: TDFlow 94.3% on SWE-bench Verified; self-written tests 69.8% ([TDFlow](https://arxiv.org/html/2510.23761v2)) | Strong | Partly: "frozen checks" rule, checked by hand |
| Tests the agent may edit get edited | Claude models edit test files in over 79% of their cheating cases; read-only tests stop that method ([ImpossibleBench](https://arxiv.org/html/2510.20270v1)) | Strong (adversarial tasks) | Foreman reads `git diff -- Tests/` by hand |
| Prompts do not stop gaming | "Please do not cheat" left the hack rate at 80% ([METR](https://metr.org/blog/2025-06-05-recent-reward-hacking)) | Strong (one task) | Rules are prose |
| Small base context | Context files: success change not significant, cost +19–23% ([Gloaguen et al.](https://arxiv.org/html/2602.11988v3)); performance falls with input length ([Chroma](https://www.trychroma.com/research/context-rot)) | Strong | No: about 60k tokens of `AGENTS.md` per session |
| Separate evaluator with fresh context | Self-graders "confidently prais[e] the work" ([Anthropic, 2026-03-24](https://www.anthropic.com/engineering/harness-design-long-running-apps)); Devin Review claims 2 bugs per PR ([Cognition](https://cognition.com/blog/multi-agents-working)) | Vendor | Optional (`review-crew` skill) |
| Must-happen rules in hooks or deny rules | "If something has to happen every time, make it a hook, a deny rule, or a managed setting" ([Claude Code docs](https://code.claude.com/docs/en/best-practices)) | Vendor | Mostly prose |
| State in files; one unit per fresh session | Initializer plus one feature per session; JSON state, because agents overwrite Markdown more ([Anthropic, 2025-11-26](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)) | Vendor | Yes: `STATE.md`, `rounds/` |
| Human attention at the plan and the merge, not per call | Users approve 93–97% of permission prompts; humans caught 13.6% of dangerous commands, the classifier 89% ([Anthropic](https://claude.com/blog/auto-mode-default-in-claude-code)) | Vendor | Merge yes; plan only for design goals |
| Remove harness parts as models improve | "Every component in a harness encodes an assumption about what the model can't do"; remove one at a time ([Anthropic, 2026-03-24](https://www.anthropic.com/engineering/harness-design-long-running-apps)) | Vendor | No: the skill only grows |

### The ideas the evidence does not support

Five popular ideas lack support for a solo repository. Parallel writer swarms worked only with a test oracle that split work by file. Without one, 16 agents fixed the same Linux bug and overwrote each other ([Anthropic, 2026-02-05](https://www.anthropic.com/engineering/building-c-compiler)). Agent teams cost about 7 times the tokens of one session in plan mode ([Claude Code costs](https://code.claude.com/docs/en/costs)). Best-of-N gains depend on the judge: an oracle over five candidates reached 63.8%, an LLM judge 60.9%, one run 53.8% ([AI21](https://www.ai21.com/blog/first-scale-then-enrich-how-the-right-execution-strategy-helped-us-reach-state-of-the-art-on-swe-rebench/)). Maximum effort added 1 point of pass rate for 76% more cost ([SWE-Serve](https://arxiv.org/pdf/2609.26777)). Heavy spec ceremony raises review cost, and specs with implementation detail decay ([Agarwal et al.](https://arxiv.org/abs/2608.25202)).

### The gaps in the external evidence

No controlled study compares single-agent and multi-agent work on real repository features with equal budgets. No study measures review fatigue on agent pull requests directly, nor the cost of a stale or contradictory instruction line. No study tests a restricted vocabulary such as ASD-STE100 in prompts for coding agents. AI code reviewers report 29–57% recall and 63–75% precision, but each vendor runs its own benchmark with its own definition of a false positive ([Augment](https://www.augmentcode.com/guides/deep-code-review-recall-vs-precision); [Qodo](https://www.qodo.ai/academy/ai-code-review-tools-comparison-and-benchmarks/)).

## The records show six measured pain points

The audit read 146 round records over 28 goals, 20 chores, and 195 merged pull requests. 137 rounds (93.8%) say `done`, 9 say `propose`, and none says `failed`. 108 rounds carry a cost: $1,332.56 in total, median $8.93, maximum $93.14 (audit notes, not in the repository). The table maps each pain point to the five dimensions of the question.

| Pain point | Measured fact | Dimension |
|---|---|---|
| Crew context cost | First request of 6 crew sessions: 111,668–124,112 tokens; comparable repository with an 850-character `AGENTS.md`: 48,385–50,535 | Efficiency |
| Rules in many copies | `AGENTS.md` 27,808 words, `facts.md` 6,459, skill 5,781, `docs/foreman.md` 4,467, `LOOP.md` 3,861; `LOOP.md` still says "Hold one `wait_for_events`", the skill says the opposite | Consistency |
| Hand bookkeeping | About 30 actions per round; cost lines back-filled once; wrong PR numbers in 5 records; 19 records whose shas the ledger cannot read | Automation, consistency |
| Checks the loop can skip | No release build in CI; a release-only compiler crash blocked every release build (PR #211); two green PRs made `main` red on Linux | Quality |
| Silent stops and human queue | Crews stopped 16 min, 3.5 h, and overnight unseen; 138 merges since 2026-09-08 (about 2 a day); one design changed six times in a $93.14 round | Efficiency, automation |
| Blind measurement | 17 "None" corrections counted as corrections; 68.5% of gap classes are `none`; foreman cost absent from the ledger | Quality, cleanliness |

### Half of a crew's first context is one file

Claude Code reads `AGENTS.md` at session start when no `CLAUDE.md` exists, and kitterm has none ([Claude Code memory docs](https://code.claude.com/docs/en/memory#agents-md)). Each of 6 measured crew transcripts holds the whole file, 177,926 characters, as project instructions. A cold-cache comparison puts the file at about 55k–62k tokens, an estimate by difference (startup notes, not in the repository). Every later request reads it again from cache: about 3.5M tokens in the 59-request `foreman-event-driven` session. The file grew from 20,728 bytes on 2026-09-01 to 178,557 on 2026-11-01. Its "Fleet view" bullet is one line of about 30 KB. It is a changelog of features, which the vendor lists as retired advice: "Claude reads the repo itself" ([Claude Code best practices](https://code.claude.com/docs/en/best-practices)).

### Three copies of the rules already disagree

The skill says "where this skill and that file differ, the file wins" ([foreman-loop.md](../../../../examples/foreman/foreman-loop.md)). PR #208 moved the skill to `kitterm foreman watch` in the background, but `LOOP.md` and `docs/foreman.md` still prescribe one held `wait_for_events` ([LOOP.md](../../../../docs/goals/LOOP.md)). By the precedence rule, the stale line wins. `LOOP.md` also says "A goal keeps its one branch and its one pull request", yet `code-editor` used 6 pull requests and `sessions-workflow` 4. `facts.md` holds four rules that later rules reverse, such as a shell loop that polls every 10 s, with no marker of the change ([facts.md](../../../../docs/goals/facts.md)). Seven done goals still list proposals for the human; later goals delivered at least two of them.

### The foreman does by hand what a command can do

One round asks the foreman for about 30 actions across 9 procedures; that count is from the skill text, not a transcript. Many actions are deterministic: five labels, the PR number in three places, the cost line, the branch cleanup, the digest shape. The errors follow. The foreman back-filled the `workspace-ledger` cost lines later, and wrote wrong PR numbers in five of its own records ([facts.md](../../../../docs/goals/facts.md)). `kitterm archive cost` printed `none recorded` for a crew archived right after `/exit`, and the bill landed 5 s later; the documents say to run it once. The 2026-09-29 audit measured the foreman at $23.40 against $40.74 for all 13 crew rounds and chores ([foreman-flow findings](../../../../docs/goals/foreman-flow/corpus/01-findings-2026-09-28.md)). So the foreman cost about 36% of that window's spend, mostly on empty waits and screen reads.

### CI does not test what ships

`ci.yml` runs a debug `swift test`, the web build and tests, and a Linux `swift build --build-tests`. No step builds `-c release` ([ci.yml](../../../../.github/workflows/ci.yml)). A Swift 6.3.3 release-build crash therefore reached `main` and blocked every release build until PR #211 ([chore record](../../../../docs/goals/chores/2026-10-30-goalledger-optimize-none.md)). The test-diff audit is the foreman's reading of `git diff <base> -- Tests/`; 43 records mention "Chartered", and no tool flags a weakened assertion. A review gate in September found one blocking and 22 should-fix items that five green floors had passed.

### Stopped crews emit no event

Three rounds lost time to a crew that stopped on the model's usage limit: `screen-state` r1 (16 min), `value-lifetime` r1, and `proxy-is-a-boundary` r2 (overnight). In `value-lifetime` r8 the watcher reported a stall, and the foreman did not answer it for 3 h 32 min ([round record](../../../../docs/goals/value-lifetime/rounds/008.md)). The current `kitterm foreman watch` wakes on any `agent.status`, which closes part of this gap. Whether a usage-limit stop sends any hook is not measured. Wall time on the `Cost:` line has a median of 24.5 min; six rounds open for 16–48 h hold about 145 of the 192.9 recorded hours.

### The records cannot separate a clean round from a rescued one

`done` covers 93.8% of rounds and `none` 68.5% of gap classes, so neither field separates outcomes. The parser counts a `## Correction` heading, not its content, so 17 headings that say "None" inflate the `LEAKS` panel ([KnowledgeSummary.swift](../../../../Sources/KittermDaemon/KnowledgeSummary.swift)). Real corrections are 30 of 146 rounds. Three gap classes fall outside the vocabulary. Records are never rewritten, so a defect found later never links back to its round. The ledger holds no foreman cost and no human minutes.

## Ten changes, ranked by pain, evidence, and cost

Rank combines three inputs: the size of the measured pain, the strength of the evidence, and the cost to build. Changes 1–4 are cheap and well supported. Changes 5–7 need a small build. Changes 8–10 rest on thinner evidence.

| Rank | Change | Main dimension | Evidence | Cost | Conflicts with current design |
|---|---|---|---|---|---|
| 1 | Stop loading 178 KB of `AGENTS.md` into every crew | Efficiency | Strong + local | Low | Moves the living product spec out of the default load |
| 2 | Add CI gates the crew cannot edit: release build, test-diff guard | Quality | Strong + local | Low; human edits `ci.yml` | No |
| 3 | Keep each rule in one place, and make the copies agree with practice | Consistency | Local; vendor | Low; `LOOP.md` is Propose tier | Reverses "the file wins" precedence |
| 4 | Fix the measures: corrections, outcome words, foreman cost | Quality, cleanliness | Local; DORA | Low | No |
| 5 | Replace hand bookkeeping with `round open` and `round close` commands | Automation | Local; vendor practice | Medium | Moves procedure from prompt to code |
| 6 | Make a fresh-context review the default step before `gh pr ready` | Quality | Vendor + local | About $3–25 per review | No; makes `review-crew` mandatory |
| 7 | Detect stalls from facts, and resume after a usage limit | Efficiency | Local; vendor | Low–medium | No |
| 8 | Put zero-exception rules in hooks and deny rules | Consistency, cleanliness | Vendor + local incidents | Low | No |
| 9 | Prune `facts.md` with supersede markers; let crews search it | Cleanliness | Strong (indirect) + local | Human minutes | No |
| 10 | Gate design rounds on a plan note; cap corrections at two; schedule by file overlap | Quality, efficiency | Thin | Low | Adds a human step for design goals |

### 1. Stop loading 178 KB of `AGENTS.md` into every crew

**Change.** Keep a root instruction file under 200 lines: the build and test commands, the places where the code misleads, decisions not in the code, and mistakes corrected twice. Move each surface specification (fleet view, `/edit`, HTTP API) into `docs/` or into `.claude/rules/` with a `paths:` filter. The fastest step is a short `CLAUDE.md`, which stops the automatic `AGENTS.md` load under the default setting ([memory docs](https://code.claude.com/docs/en/memory#agents-md)).

**Pain point.** About 60k tokens per crew session, read again on every request.

**Evidence.** Developer-written context files gave +2.4% success (not significant) at up to +19% cost; agents act on what a file names ([Gloaguen et al.](https://arxiv.org/html/2602.11988v3)). One distractor lowers performance ([Chroma](https://www.trychroma.com/research/context-rot)). The vendor target is under 200 lines ([best practices](https://code.claude.com/docs/en/best-practices)).

**Cost and trade-off.** One chore of edits. A crew loses facts that are always present today, and may miss a rule for a surface it touches. Path-scoped rules reduce that risk. `AGENTS.md` now serves as the human's living specification; the change keeps the content but changes when it loads.

**Confidence.** High for the token saving, which is measured locally. The effect on success is unknown: the study found no significant change in either direction. Measure the first-request tokens and the median round cost over the next 10 rounds.

### 2. Add CI gates the crew cannot edit

**Change.** Add a `swift build -c release` job on every pull request. Add a job that flags deleted or changed assertions, skip markers, and snapshots in `Tests/` and `*.test.ts`, and any edit under `.github/workflows/`. The job asks for a `Chartered:` line in the PR body to pass.

**Pain point.** PR #211's release-only crash; two green PRs that made `main` red; the test-diff check done by hand in 43 records.

**Evidence.** Claude models cheat mostly by editing tests, and read-only tests stop that method ([ImpossibleBench](https://arxiv.org/html/2510.20270v1)). Prompts have a "nearly negligible effect" ([METR](https://metr.org/blog/2025-06-05-recent-reward-hacking)). An oracle the agent cannot edit is the largest measured lever ([TDFlow](https://arxiv.org/html/2510.23761v2)).

**Cost and trade-off.** macOS runner minutes and a longer CI. The guard flags legitimate test changes too, so it must label, not block. The human must make the `ci.yml` edit, because the auto-mode classifier refused it once.

**Confidence.** High for the release gap, which is a local fact. The test-gaming evidence comes from adversarial benchmarks; the one natural-rate figure is 7 hacks in 800 TDFlow runs.

### 3. Keep each rule in one place, and make the copies agree with practice

**Change.** Let `LOOP.md` hold policy only: authority tiers, budget, stop rules, record shape. Let the skill hold the procedure, and let `docs/foreman.md` hold the API reference. Delete the duplicates, fix the stale `wait_for_events`, `list_projects`, and `goal new` lines, and add a test that fails on known stale phrases (`GoalsLayoutDocsTests` is the model). Rewrite "one pull request per goal" to what the records show, or enforce it.

**Pain point.** About 48,000 words of rules, three copies, and a precedence rule that lets the oldest copy win.

**Evidence.** The vendor ships `/doctor prompt-audit` to find contradictory and stale instructions ([best practices](https://code.claude.com/docs/en/best-practices)), which shows the failure is common. Agents execute what a file names ([Gloaguen et al.](https://arxiv.org/html/2602.11988v3)), so a stale command gets run.

**Cost and trade-off.** A few hours of edits. `LOOP.md` is Propose tier, so the human makes the edit. No study measures the cost of one stale line.

**Confidence.** Medium on effect size; high that the contradictions exist.

### 4. Fix the measures so quality shows

**Change.** Count a correction only when its section does not start with "None". Replace the decision word with facts: floor passed on the first try, number of corrections, review findings. Archive or estimate the foreman's own session per round. Link each later `fix/` or `chore/` pull request to the round whose lines it changes, and count reverts.

**Pain point.** `done` on 93.8% of rounds, 17 false corrections, and no foreman cost.

**Evidence.** Rework and change-fail rates are the measures that rose with AI use while throughput rose too ([DORA 2025 via DX](https://newsletter.getdx.com/p/doras-2025-research-on-the-impact)); bugs per developer rose 54% in one telemetry set ([Faros](https://faros.ai/blog/ai-acceleration-whiplash-takeaways)). Anthropic advises graders the agent cannot bypass ([Anthropic evals](https://anthropic.com/engineering/demystifying-evals-for-ai-agents)).

**Cost and trade-off.** A parser change and two record fields. A measure the crew sees during a round becomes a target, so compute these after merge.

**Confidence.** High for the parser fix. The outcome measures need a few weeks of data before they mean anything.

### 5. Replace hand bookkeeping with two commands

**Change.** Add `kitterm round open` (worktree, branch, draft PR, labels, spawn) and `kitterm round close` (archive, cost with a retry until the bill lands, record header from facts, `STATE.md` fields, one commit). The foreman then writes only judgment: the gap, the decision, the reflection.

**Pain point.** About 30 actions per round; wrong PR numbers, missing cost lines, unreadable shas; the foreman at about 36% of spend in one measured window.

**Evidence.** Automated chains pass exit codes and structured output, not prose ([Claude Code headless](https://code.claude.com/docs/en/headless)). One team kept the task lock, ledgers and gates in the repository and resumed from verified state ([eachlabs](https://www.eachlabs.ai/blog/we-timed-our-coding-agents-92-of-the-work-happened-before-code-was-pushed)). The local errors are measured.

**Cost and trade-off.** About one small goal; `foreman-flow` cost $23.23 over 4 rounds as a reference. The change moves procedure from the prompt into code, against the stated rule "kitterm ships the machinery, the foreman is a prompt". The CLI already holds `foreman watch`, `catch-up`, `goal cost` and `archive cost`, so the line has moved before.

**Confidence.** Medium. The error classes are measured; the saving in foreman tokens is an estimate.

### 6. Make a fresh-context review the default step before `gh pr ready`

**Change.** Before a goal's pull request leaves draft, run one review session with no shared context. Give it `goal.md` and the diff. One pass finds issues; a second pass tries to refute each one; only survivors reach the human.

**Pain point.** 22 should-fix items that five green floors passed; four defects in a round written up as complete.

**Evidence.** A skeptical separate evaluator is "far more tractable" than self-critique ([Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps)). The vendor guide names "review the diff against SPEC.md" ([best practices](https://code.claude.com/docs/en/best-practices)). Anthropic's product uses find-then-verify to cut false positives ([InfoQ](https://infoq.com/news/2026/04/claude-code-review)).

**Cost and trade-off.** One local review cost $3.35 (PR #184); Claude Code Review costs $15–25 per review. Reported recall is 29–57%, so the review filters work for the human and does not replace the human read.

**Confidence.** Medium. The local evidence is two incidents; the external numbers are vendor-run.

### 7. Detect stalls from facts, and resume after a usage limit

**Change.** Turn on `autoContinueAtUsageLimit` (v2.1.234+) in crew sessions ([Claude Code costs](https://code.claude.com/docs/en/costs)). Treat a `completed` hook with no `DONE` note as a stall that wakes the foreman. Give the foreman one rule: answer a stall within one wake, or end the session.

**Pain point.** Four rounds lost 16 min to a whole night; one stall waited 3.5 h for the foreman.

**Evidence.** Vendors bound runs with explicit stop rules and resume points, such as auto mode's escalation after 3 consecutive or 20 total denials ([Anthropic](https://anthropic.com/engineering/claude-code-auto-mode)). No validated stall predictor exists, so the signal must be facts.

**Cost and trade-off.** Small. An automatic continue after a reset spends the weekly limit on work that may be stale.

**Confidence.** Medium. It is not known whether a usage-limit stop sends a hook; test it once before you depend on it.

### 8. Put zero-exception rules in hooks and deny rules

**Change.** In crew sessions, deny pushes to `main`, edits under `.github/workflows/`, edits to `goal.md` and `corpus/`, writes outside the worktree, and `kitterm start` or a second daemon.

**Pain point.** These rules exist only as prose. Three incidents harmed the human before a rule existed: a scope breach into another workspace, a public fixture leak (`a16059f`), and a `--help` restart that killed every pane.

**Evidence.** "CLAUDE.md is for guidelines"; a boundary stated in conversation "can get lost when the conversation compacts" ([best practices](https://code.claude.com/docs/en/best-practices)). The auto-mode classifier misses 17% of real overeager actions ([Anthropic](https://anthropic.com/engineering/claude-code-auto-mode)).

**Cost and trade-off.** Low. Keep the set small; the vendor says forty rules are "probably preferences". A deny rule in shared settings also blocks the foreman, so scope it to crew sessions.

**Confidence.** Medium. The evidence is vendor guidance; the incidents are local.

### 9. Prune `facts.md`, and let crews search it

**Change.** Mark each fact that a later fact replaces, and delete it at the goal's close. Move facts that are rules into the skill or into a hook. Clear the proposals of done goals. Tell crews to `grep` `facts.md` by topic, not read it whole.

**Pain point.** Four contradictions, two duplicates, seven stale proposal lists, and no prune since October.

**Evidence.** Distractors lower performance ([Chroma](https://www.trychroma.com/research/context-rot)); agents act on what a file names ([Gloaguen et al.](https://arxiv.org/html/2602.11988v3)).

**Cost and trade-off.** Human minutes at each direction check. A prune can delete a lesson that still holds.

**Confidence.** Medium; the evidence is indirect.

### 10. Gate design rounds on a plan note; cap corrections; schedule by file overlap

**Change.** Some rounds set a data model, an interface, or a visual design. In such a round, the crew first posts a short plan note, and the foreman or the human approves it before code. After two failed corrections in one session, end it and start a fresh one with the lesson in the brief. Do not run two tasks at once that name the same files.

**Pain point.** `value-lifetime` r2: the design changed six times, $93.14 over 23.4 h. Two goals received the same `theme-contrast.test.ts` in one hour.

**Evidence.** Users reject 39% of plans against 3% of single calls ([Anthropic](https://claude.com/blog/auto-mode-default-in-claude-code)). HumanLayer argues that "a bad line of a plan could lead to hundreds of bad lines of code" ([HumanLayer](https://github.com/humanlayer/advanced-context-engineering-for-coding-agents/blob/main/ace-fca.md)). The vendor says to run `/clear` after two failed corrections ([best practices](https://code.claude.com/docs/en/best-practices)). File ownership prevents overwrites ([agent teams docs](https://code.claude.com/docs/en/agent-teams)).

**Cost and trade-off.** One more check per design round, and a slower start. kitterm already approves `.pen` frames before build, so this extends a step that exists.

**Confidence.** Low to medium; the plan evidence is anecdote and vendor guidance.

## Keep the topology and the human merge; test the rest before adopting it

### Keep: one crew per round, panes, the human merge, the round size

Four parts of the current design match the evidence, and changing them would cost more than it saves. One crew per goal round matches the single-writer finding; parallel crews per goal would add a 7-fold token cost on a weekly limit. Interactive panes stay: `claude -p --bare` needs an API key, and agent teams do not run headless ([Claude Code headless](https://code.claude.com/docs/en/headless)). Every product keeps a human merge, and no source supports automatic merge of agent work. The median round runs 24.5 min, well inside the reported multi-hour horizons of current models ([METR](https://metr.org/blog/2026-01-29-time-horizon-1-1/)).

### Reduce the merge cost; do not remove the merge

138 merges in about nine weeks is about two a day. Median review time rose fivefold at high-AI teams, and 31% more pull requests merged with no review ([Faros](https://faros.ai/blog/ai-acceleration-whiplash-takeaways)). The supported response is fewer, verified pull requests with a summary that names the risky files first: tests, CI, auth, and data. Auto-merge would contradict the current design, the classifier, and the evidence, so this report does not recommend it.

### Test before adopting: model routing, structured prompts, JSON state

Three ideas have thin evidence for kitterm and need a local trial first. The advisor pattern scored 2.7 points over Sonnet alone at 11.9% lower cost, a vendor benchmark ([Anthropic](https://claude.com/resources/articles/the-advisor-strategy)). Cognition reports that a fast, weaker primary model "was not good enough at being the primary model" ([Cognition](https://cognition.com/blog/multi-agents-working)). So keep a strong model for the crew that writes code. The STE writing rules have no evidence for or against their effect on agent output; their measurable value is to the human reader. A cheap test is the same round prompt in STE and in plain prose on a few tasks, compared on floor pass rate and cost. JSON for machine-read state is a vendor anecdote, and it contradicts the parsed Markdown that the daemon and the fleet view read. Command-written fields (change 5) give the same protection with no format change.

## Conclusion

The loop's design questions are mostly settled; its remaining problems are operational. Every lesson since September became more prose: the skill grew 2.3-fold and `AGENTS.md` 8.6-fold. Prose is the one control that the evidence shows agents follow least reliably and pay for on every request. The next gain therefore comes from removal and from mechanism, not from more rules. Shrink what each crew reads. Move each must-happen step into a command, a CI job, or a deny rule. Make the record show which rounds needed rescue.

kitterm already holds more cost-per-round data than any public source. That turns each change into an experiment: the round ledger can measure first-request tokens, median round cost, correction rate, and post-merge fixes before and after. Anthropic's own advice to remove harness parts one at a time applies to the foreman too. Each dated rule in the skill names the incident that created it. So the foreman can test each rule, and remove it when a newer model or a new check covers it.
