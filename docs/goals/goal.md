# Goal: projects on the fleet view, and a knowledge base per project

Status: active (opened 2026-09-08).

## Objective

A human opens `/sessions` on any device and sees the work grouped by
project: what runs, what needs them, what failed, and what each goal loop
does next. A foreman reads this directory before every round and writes it
after every round, so no round rediscovers a fact, a decision, or a plan.

The two parts:

1. **Projects.** The daemon resolves each session's project from its live
   cwd and reports it as a fact. The fleet view groups sessions by project,
   shows counts and attention items, and offers kill, archive, and spawn.
2. **Knowledge.** Each project keeps this package, `docs/goals/`, in its
   repository. The repository is the control plane. The daemon reads the
   package for the dashboard and never writes it.

## Exclusions

- No task model, kanban, or AI in the daemon.
- No daemon-side write into any repository.
- No git operation by the daemon beyond a walk for `.git`.
- No multi-machine foreman.
- No push notification from the dashboard (issue #21 stays separate).
- No rendered Markdown view on the dashboard; titles and links only.
- No new WebSocket opcode.

## Completion condition

All four hold on a daemon built from `main`:

1. On a phone at 390 px, `/sessions` shows a running crew under its project
   card, a failed human pane in the attention strip, and a pending approval
   answerable from the strip. Kill and archive work from the phone.
2. A project card shows the goal title, the next action, and the round
   budget read from `docs/goals/STATE.md`, and the values match the file.
3. `kitterm skills install` puts the same skills in `~/.claude/skills/` that
   `examples/foreman/` holds, and a second run reports no change.
4. One goal ran three rounds through the `goal-loop` skill, and
   `docs/goals/rounds/` holds the three records with a floor result and a
   gap class each.

The floor (`swift test`, `KittermBench` p95 under 50 ms, `pnpm build` and
`pnpm test`) is green at every step.
