# Plan

The initial floor and the expected capability order for the goal in
`goal.md`. A human owns this file. A foreman proposes a change to it in a
round record; it does not edit it.

## The floor

The floor holds earned behaviour. It starts green and must stay green. A red
floor makes the regression the next round's job.

| Check | Command | Pass condition |
|---|---|---|
| Daemon and CLI tests | `swift test` | exit 0 |
| I/O latency | `swift run KittermBench` against a running daemon | `interactive-echo` p95 under 50 ms |
| Web build and tests | `pnpm build && pnpm test` in `Web/terminal` | exit 0 |
| Linux build | `swift build` in `swift:6.1` (see AGENTS.md) | exit 0, on a phase that touches `Sources/` |

Each round adds at least one deterministic check for the behaviour it
closes. A check that exists is frozen (see `LOOP.md`).

## Capability order

Six capabilities. Each ships as one PR. Each names the check that proves it.

| # | Capability | Proof |
|---|---|---|
| 1 | **Project identity on the daemon.** `~/.kitterm/projects.json` (`{version, projects:[{id, name, root, knowledge?}]}`), longest-prefix then `.git` walk with a `gitdir:` follow, resolved when `liveCwd` changes. Row fields `project {id, name, root, registered}` and `orchestrated`. Reserved label keys `project`, `goal`, `round`. `GET /api/projects` with counts by `mergedState`, pending approvals, `lastOutputAt`, archive count. `?project=` on sessions and archives. `kitterm project add / list / remove`. MCP tool `list_projects`. | Resolution table test: registered wins, git walk, worktree `gitdir:`, no project, label override. Aggregate route test. Bench unchanged. |
| 2 | **The dashboard.** `sessions-model.ts` with pure `group`, `sortInGroup`, `filter`, `attention`. Attention strip. One card per project with counts and spawn-in-project. Rows with kill and archive behind a confirm. Crew sub-headers. Archived rows under their project. Filter chips and text search. Phone layout at 390 px. Link from the settings panel. The session labelled `crew:foreman` renders as one pinned row above the cards; when none exists the attention strip reads "no foreman running". Poll becomes `/api/projects` plus `/api/sessions`. | Vitest on every pure function. Corpus request `01-phone-dashboard`. |
| 3 | **Scaffold and docs.** `kitterm project init <path>` copies this package's templates into `docs/goals/` and registers the project. `docs/foreman.md` names all 15 tools. `docs/architecture.md` state tree matches `DaemonPaths.swift`. | CLI test on a temp dir. Doc diff reviewed. |
| 4 | **The foreman skill and skill install.** `examples/foreman/foreman-loop.md` becomes the standing foreman from `LOOP.md`: scan, schedule, delegate one round, monitor, report, direction. `review-crew` and `triage` become procedures the foreman delegates inside a round; each posts into the round record when a `goal:` label is set. `docs/foreman.md` gains the multi-project loop and the report shape. `kitterm skills install` copies `examples/foreman/*` into `~/.claude/skills/` and reports the diff. | CLI test: install, second run reports no change. Completion condition 3. Corpus request `03`. |
| 5 | **Knowledge on the dashboard.** `GET /api/projects/<id>/knowledge/<path>`: read-only, jailed to the knowledge directory, symlinks refused, 256 KiB cap. The daemon parses the title, the `## Next action` section, and the round counter from `STATE.md`. Project card shows goal, next action, budget, last floor result, a link to the round record, and the sessions whose `goal:` label matches. A round record with decision `propose` appears in the attention strip. | Jail escape tests. Corpus request `02-project-card-state`. |
| 6 | **Dogfood.** Run capability 2 as a goal through the foreman with a three-round budget, with a second project registered. Fold the reflections into `facts.md` and the skills. | Corpus request `03-goal-loop-dogfood`. Completion condition 4. |

Capability 6 depends on 4. Capabilities 1 and 3 are independent. Capability
2 depends on 1. Capability 5 depends on 1 and 2.
