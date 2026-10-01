# Plan: foreman-scope

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift | `swift test` | exit 0, 963 tests at the start |
| CI | the PR's `ci.yml` run (`test`, `linux-build` with `--build-tests`) | green on the PR's head sha |

`LOOP.md`, "The floor": no local rerun when the base is green; the crew
runs `swift test` once and pushes.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **The check.** `kitterm project init --refresh --check <root>` compares the project's `LOOP.md` with `GoalsTemplates.loop` and `loopHistory`: `current` when it equals the current template, `behind` when it equals an older shipped one, `edited` otherwise. It writes nothing and exits 0; a missing file or a missing project exits 1 with the path. | A CLI test over three fixture roots, one per answer, and one with no `LOOP.md`. |
| 2 | **The catch-up.** `kitterm foreman catch-up [--scope <path>]`, no daemon needed for the files, the daemon's HTTP API for live sessions when it answers: the predecessor (newest live or archived `crew:foreman…` session whose cwd or `scope:` label is under the scope), its `note`, and the last assistant message of its `agentTranscript`; the goals not done per project in scope (`KnowledgeSummary`: status, round, next action); the live sessions with a `goal:` label in scope; the worktrees under each project's `.claude/worktrees/`. It prints nothing from outside the scope. | A CLI test over a fixture state directory with two scopes, which shows only the chosen scope. |
| 3 | **Scope and upkeep in the texts.** The skill and `LOOP.md` (the parts the Charter names): the scope rule and the `scope:<path>` label; "one foreman per scope"; the start step runs `kitterm foreman catch-up` first; the upkeep step runs the check for each project in scope and opens a chore PR (`behind`) or a draft proposal PR (`edited`); a foreman never acts on a project outside its scope. | The golden and sentence tests green; a new sentence test for the new rules. |

Capabilities 1 and 2 first, so that the texts of capability 3 name
commands that exist.
