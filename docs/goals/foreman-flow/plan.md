# Plan: foreman-flow

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift | `swift test` | exit 0, 931 tests at the start |
| Web | `Web/terminal`: `tsc --noEmit && vite build && vitest run` | exit 0 |
| CI | the PR's `ci.yml` run (`test`, `linux-build` with `--build-tests`) | green on the PR's head sha |
| Bench | `swift run KittermBench interactive-echo --port <scratch>` | p95 under 50 ms, only when the output path changes |

From capability 1 on, the PR exists before the crew starts, so the PR's CI
is part of the floor of every round, this goal's included.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **The PR opens first.** The foreman cuts the branch and worktree, commits the queue line, pushes, and opens a draft PR before it spawns the crew. The PR number goes on the queue line, on a `pr:<N>` label of the crew session (a reserved key in `LOOP.md`'s Labels table and in `SessionLabels`), and in the record header. Crews push to the branch; the rule "do not push" becomes "push to your branch, never to `main`". A goal keeps one branch and one PR for all its rounds; the foreman runs `gh pr ready` when the goal is done and rebases every open PR onto `main` after a merge, so its CI meets every new check. `LOOP.md` ("One round", "Chores", Labels), its template and embedded copy, the foreman skill and its embedded copy, and `docs/foreman.md` say so. | The golden and sentence tests (`ForemanSkills`, `GoalsTemplatesTests`, `GoalsLayoutDocsTests`) green; a test that `pr` is a reserved label key; this goal's own rounds 2 and 3 run by the new procedure, visible in their PRs. |
| 2 | **The dashboard shows the open PR.** When a live session carries `goal:<slug>`, `task:<slug>` and `pr:<N>`, and `STATE.md` on the main checkout does not list that task yet, the fleet view draws the task line under its goal from the labels: the task mark, `[working]`, and `PR #N` as a link (`pullRequestLink`). A task `STATE.md` does list takes the label's PR when its own line names none. No new cell and no new token: the task line of the `Components` frame. | A vitest over `taskLines` with a labelled session and no queue line; `sessions-pr-links.test.ts` extended in a new file; a screenshot of the real page during round 3 of this goal, showing its own task and PR. |
| 3 | **The CI is the second floor.** The foreman skips the floor before a round when `gh run list --workflow ci.yml --branch main` shows the base sha green, and after the crew it waits on `gh pr checks <N>` instead of running `swift test` and the Linux pipe itself. The crew runs `swift test` once and pushes; the Linux docker run leaves the crew's floor, because `linux-build` runs it. The bench stays local and runs only when a round touches the output path. The skill and `LOOP.md` say so. | Three rounds after the change, with each record's wall time and crew API time; the non-crew share below 56%. |
| 4 | **The bookkeeping is a command.** `kitterm archive cost <id> --line` prints the `- Cost:` line in `LOOP.md`'s shape (or `- Cost: none recorded (<reason>)`), and `--json` prints the bill as the route gives it. A chore's line moves out of the shared tail of `CHORES.md` (see the open question below), so two chore PRs never touch the same lines. | A CLI test over a fixture archive with a bill, one with none, and one with no transcript; two chore branches from one base merged both ways with `git merge-tree` and `swift test` green on each result. |

Capability 1 first: capabilities 2 and 3 need the PR to exist before the
crew starts. Capability 4 last; it removes the throwaway script the foreman
uses today.

## Open question for the human

`CHORES.md` conflicts because every chore appends its line at the end. Two
fixes, both inside capability 4:

- **One file per chore**: `docs/goals/chores/<ISO date>-<slug>.md`, one line
  each, and `CHORES.md` becomes a short pointer. No two chores touch one
  file. `GoalsLayoutDocsTests` and the templates learn the new path.
- **The line after the merge**: the chore's PR description carries the line,
  and the foreman appends it to `CHORES.md` in the next goal's PR. No layout
  change, but the line lands one PR later.

The foreman recommends one file per chore.
