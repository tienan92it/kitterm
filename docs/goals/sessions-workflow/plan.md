# Plan

The initial floor and the expected capability order for the goal in
`goal.md`. A human owns this file. A foreman proposes a change to it in a
round record; it does not edit it.

## The floor

The floor holds earned behaviour. It starts green and must stay green. A red
floor makes the regression the next round's job.

| Check | Command | Pass condition |
|---|---|---|
| Linux build | the `facts.md` docker pipe; the pull request's `linux-build` check proves it | `Build complete`, 0 errors |
| Swift tests | `swift test`, once by the crew; the pull request's `test` check proves it again | exit 0 |
| Web | `Web/terminal`: `tsc --noEmit`, `vite build --outDir <scratch>`, `vitest run` | exit 0 |
| Bench | `swift run KittermBench interactive-echo --port <scratch daemon>`, only for a round that touches the output path or the attach path | p95 under 50 ms |

Each round adds at least one deterministic check for the behaviour it
closes. A check that exists is frozen (see `LOOP.md`).

A round that changes the page ships the proofs of
`docs/goals/agent-dashboard/corpus/design-foundation.md`: a vitest, a CSS
assertion, screenshots at 390 px and 1200 px against the real
`docs/goals/` tree from a scratch daemon, and the page height at both
widths before and after. The design foundation (tokens, marks, fonts,
`--line-h`) still holds; this goal changes the SESSIONS section's
structure, not the foundation.

## Capability order

5 capabilities. They ship on one branch, `goal/sessions-workflow`, and
one pull request. Each names the check that proves it.

| # | Capability | Proof |
|---|---|---|
| 1 | **The design.** Three frames in a new file, `docs/goals/sessions-workflow/design/sessions.pen`: `Sessions 1200`, `Sessions 390`, and `Sessions components` (one line per stage at each level, each pull request state, the review line, the no-`gh` line). The frames draw the real tree of 2026-10-03, on the foundation's tokens. The crew edits no other `.pen` file. | The human approves the frames in Pen. The foreman then copies the file to `corpus/sessions.pen` and records the approval. |
| 2 | **Pull request state.** `PullRequestStatus` in `KittermDaemon`: for every project whose `origin` is on GitHub, `gh pr list --state all --limit 50 --json number,title,state,isDraft,headRefName,mergedAt,url,statusCheckRollup,additions,deletions` on its own queue, at most once a minute per project, cached, with a reason when `gh` is absent, logged out, or fails. A route, `GET /api/projects/<id>/pulls`, answers the cache, full grade, with an `ETag`. | New tests with a fake `gh` on `PATH`: the parse, each reason, the one-minute bound, and no call on the event loop. |
| 3 | **The merged base branch.** The knowledge summary of a project reads `STATE.md`, `goal.md` and `rounds/` from `origin/<base>` after a `git fetch` on its own queue, at most once a minute, through `git` objects, not the working tree; with no remote, or a failed fetch, it reads the working tree as today and says which. | New tests against a scratch bare repository: a commit pushed to the bare repository shows in the summary with no change to the working tree; the fallback; no symlink or path outside the knowledge directory is read. |
| 4 | **The stage.** A pure `sessions-stage.ts` decides the stage of each goal and task line from `STATE.md`, the session rows and the pull request state, by the table in `corpus/00-request.md`. | A vitest with one case per row of the table, and per level. |
| 5 | **The tree.** `sessions-tree.ts` and `sessions.css` draw the SESSIONS section as `corpus/sessions.pen` shows it: the stage word, the pull request state, the review line, the no-`gh` line. | The proofs of the design foundation, and the completion conditions 1, 4, 6 and 7. |

Capabilities 2 and 3 do not depend on the design, so rounds 2 and 3 run
while the human reviews the frames of round 1: the approval blocks only
capability 5. Capability 4 depends on 2. Capability 5 depends on 1 and
4. One round of this goal runs at a time (`LOOP.md`).
