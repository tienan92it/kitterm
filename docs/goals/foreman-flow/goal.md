# Goal: a PR from the start, and fewer stops for the human

## Objective

Today a round's PR opens at its end, one goal can make several PRs, and the
human merges each one and sorts out the order. A running round is invisible
on the fleet view, because the daemon reads `docs/goals/` from the main
checkout and the round's work lives on a branch. More than half of a round's
wall time is builds the CI already runs and bookkeeping the foreman does by
hand (`corpus/01-findings-2026-09-28.md`).

After this goal, every goal and every chore opens a draft PR before its crew
starts. The crew pushes to it, so the human can watch the diff while the work
runs. The fleet view shows the running round's task and its PR link at once.
A goal has one PR for all its rounds, and the human merges once, when the
foreman marks it ready. The foreman stops rebuilding what the PR's CI
already proves, and a command writes the bookkeeping it did by hand.

## Exclusions

- The foreman does not merge. The human merges; the auto-mode classifier
  refuses `gh pr merge`, and that stop is the human's review.
- No change to the daemon's rule "says which sessions it holds, and never
  judges them". The fleet view shows what labels and files say.
- The screen-state classifier is issue #171, not this goal.
- The foreman's own model and polling cost are not this goal.
- No change to what a Propose-tier file is. `ci.yml`, `Package.swift` and
  `plan.md` still go to the human.

## Charter

The human approves this package by merging it. That approval charters the
rounds of this goal to edit `docs/goals/LOOP.md`, its template
`examples/goals/LOOP.md` with the embedded copy in `GoalsTemplates.swift`,
the foreman skill `examples/foreman/foreman-loop.md` with its embedded copy
in `ForemanSkills.swift`, and `docs/foreman.md`, where a capability below
names the change. Nothing else in the Propose tier.

## Completion condition

All six hold on a build from `main`:

1. Every round and chore started after capability 1 opens a draft PR before
   its crew starts: its number is on the queue line in `STATE.md`, on the
   crew session as a `pr:<N>` label, and in the round record's header. The
   crew pushes its commits to the PR's branch. A goal's rounds share one PR,
   and the foreman marks it ready when the goal is done.
2. While a round runs, the fleet view shows its task line under its goal,
   with the state word and `PR #N` as a link, before anything merges; a
   vitest pins it and a screenshot of the real page shows it.
3. The foreman does not run the floor before a round when the base sha's
   `ci.yml` run on `main` is green, and it reads the PR's CI instead of
   running `swift test` and the Linux build again after the crew. Three
   rounds measured after this change have a non-crew share of wall time
   below the 56% of the findings.
4. `kitterm archive cost <id> --line` prints the round record's `- Cost:`
   line in `LOOP.md`'s shape, or `none recorded (<reason>)`, and `--json`
   prints the bill; no round record needs a second commit to name its PR.
5. Two chore PRs opened on the same day merge in either order with no
   conflict.
6. `main` is green after each merge.

The floor (`swift test`, the web suite, the PR's `ci.yml` run, and the bench
when a round touches the output path) is green at every step.
