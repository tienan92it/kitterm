# Plan: round-commands

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift | `swift test` | exit 0 |
| Release | `swift build -c release --product kitterm` | exit 0 |
| CI | the pull request's `ci.yml` run | green on the head sha |

The crew runs the first two once after its work. Round 1 changes one
field of one route and no file under `Web/`; rounds 2 and 3 change the
CLI alone. No round touches the output path, so the bench does not run.
The release build is the crew's own check until `ci.yml` runs it.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **A correction counts only when one happened.** `KnowledgeSummary.roundRecord` reads the text of the `## Correction` section and answers `correction: false` when it is absent, empty, or starts with "None". The stale pointer in `KittermMain.swift` (`see AGENTS.md "Projects"`) names `docs/http-api.md`. | Completion conditions 1 and 2. The `DONE` note gives the count of records under `docs/goals/` whose answer changed. |
| 2 | **`kitterm round open <root> <slug> --task <item>`.** The command resolves the base branch as `KnowledgeBase` does. On a first round it adds the worktree `.claude/worktrees/<slug>` on `goal/<slug>` from `origin/<base>`, commits the queue line, pushes, and opens the draft pull request with `gh`. It writes `, PR #N.` on the queue line, commits and pushes. On every round it refuses when a live session carries `crew:<slug>`, takes the round number from `STATE.md`, and spawns one session in the worktree through `POST /api/sessions` with the five labels. `--chore` uses `chore/<slug>`, an empty opening commit, and no goal folder. `--title` and `--body` feed the pull request. The crew posts a `PLAN` note with the flags and the output shape before it writes code. | Completion conditions 3 and 4. |
| 3 | **`kitterm round close <root> <slug>`.** The command finds the round's sessions by label, archives each, and reads each bill with a retry (`bill-lands-seconds-after-exit` in `facts.md`). It writes the record header from facts, the six sections with markers, the `- Foreman:` line, and the `STATE.md` fields. `--commit` refuses while a marker remains, then commits the goal's folder and pushes. `--chore` writes the one chore file with its cost. | Completion conditions 5, 6 and 7. |

Rounds 2 and 3 each add the lines their command writes to "Parsed
shapes" of `LOOP.md` (Chartered). Each round adds one deterministic
check for its capability.
