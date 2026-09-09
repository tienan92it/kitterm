# Goal: one folder per goal under docs/goals

## Objective

A project keeps many goals at once. Each goal is one folder,
`docs/goals/<slug>/`, with `goal.md`, `plan.md`, `STATE.md`, `corpus/`,
and `rounds/`. The project keeps `LOOP.md` and `facts.md` at
`docs/goals/`. A goal's status lives in its `STATE.md` as `active`,
`waiting`, `stopped`, or `done`; a goal never moves. A new goal is a new
folder made from the template. The daemon, the dashboard, the CLI, the
templates, the skill, and the docs all read the same layout.

## Exclusions

- No change to the round procedure, the tiers, or the record shape.
- No migration tool for other repositories: `kitterm project init` writes
  the new layout; an old flat package is edited by hand.
- No goal-level `facts.md` or `LOOP.md`.

## Completion condition

All five hold on a daemon built from `main`:

1. `kitterm project init <path>` writes `docs/goals/LOOP.md` and
   `facts.md` only, and `kitterm goal new <path> <slug>` writes
   `docs/goals/<slug>/` from the template, refusing an existing folder.
2. `GET /api/projects/<id>/knowledge` returns one summary per goal folder
   with the folder name as `slug` and its `status`; the file route serves
   `<slug>/rounds/NNN.md`.
3. The project card shows every goal: `active` and `waiting` ones with
   their round, next action, proposals, and record link; `stopped` and
   `done` ones as one line each with the status. Sessions with a `goal:`
   label group under that goal.
4. The installed `foreman-loop` skill scans every goal folder, schedules
   only `active` ones, writes the record under the goal's folder, and
   handles `done` and `new goal` as `LOOP.md` says.
5. Corpus request `04-goal-folders` passes on this repository's own
   package, which holds one done goal and this active one.

The floor (`swift test`, `KittermBench` p95 under 50 ms, `pnpm build` and
`pnpm test`) is green at every step.
