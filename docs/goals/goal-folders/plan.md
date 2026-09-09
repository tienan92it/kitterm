# Plan

## The floor

The same floor as `projects-and-knowledge/plan.md`: `swift test`,
`KittermBench interactive-echo` p95 under 50 ms, `tsc`, `vite build`,
`vitest`, and the Linux build once per capability that touches `Sources/`.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **Templates and CLI.** `examples/goals/` splits into the project files (`LOOP.md`, `facts.md`) and `examples/goals/goal/` (`goal.md`, `plan.md`, `STATE.md`, `corpus/.gitkeep`, `rounds/.gitkeep`). `GoalsTemplates.swift` embeds both sets with the golden test. `kitterm project init <path>` writes the project files and registers; `kitterm goal new <path> <slug> [--knowledge <dir>]` writes the goal folder, refusing an existing one; `kitterm goal list <path>` prints each folder with its status. | Golden test; CLI tests on a temp dir: init writes two files, goal new writes five, refusal, list. |
| 2 | **Daemon summary per goal.** `GET /api/projects/<id>/knowledge` returns `{project, goals: [summary]}`; each summary is today's shape with `slug` from the folder name, `lastRecord` as `<slug>/rounds/NNN.md`, sorted `active`, `waiting`, `stopped`, `done`, then by slug. A package with no goal folder answers an empty list. The ETag covers the whole body. | `KnowledgeSummaryTests` on a fixture with three folders; `KnowledgeRouteTests` for the shape, the order, the empty list, the record path; this repository's own package as a fixture. |
| 3 | **Dashboard per goal.** The card lists goals: `active` and `waiting` expanded (title, `round N of M`, status, next action, proposals link, record link), `stopped` and `done` as one line with the status; `goal:` sub-headers per goal; proposed items per goal with the dismiss key `${project}:${slug}:${round}`. | Vitest on `goalGroups` and `proposedItems` with several goals; corpus request `04-goal-folders` at 1200 px and 390 px. |
| 4 | **Skill and docs.** `examples/foreman/foreman-loop.md` scans every `docs/goals/<slug>/STATE.md`, schedules only `active`, writes the record under the goal's folder, names the goal's files in prompts, handles `done` and `new goal` as `LOOP.md` says; `review-crew` and `triage` write into the goal's `rounds/`. `docs/foreman.md`, `AGENTS.md` "Control plane" and the knowledge bullets, and `examples/goals/LOOP.md` say the same layout. `kitterm skills install` carries the new skill. | `ForemanSkillsTests` golden; a diff of every `docs/goals` mention in the docs against the layout; completion condition 4 by a fixture run. |

Capability 2 depends on 1 for the template only. Capability 3 depends on
2. Capability 4 is independent and can run alongside 2.
