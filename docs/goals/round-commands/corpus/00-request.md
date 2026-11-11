# Request: changes 4 and 5 of the workflow revamp

2026-11-10. The human asked for a revamp of the foreman and crew
workflow, read the research report, and answered **"all changes"**. The
request, the routing of the ten changes and the report are in
`docs/goals/lean-context/corpus/00-request.md` and
`docs/goals/lean-context/corpus/01-research-report.md`. This goal does
not copy them.

This goal runs two rows of that routing table:

| Change | Round |
|---|---|
| 4. Fix the measures so quality shows | 1 (the correction parser), 3 (the foreman's cost) |
| 5. Replace hand bookkeeping with two commands | 2 (`kitterm round open`), 3 (`kitterm round close`) |

Two parts of change 4 do not run here: the link from a later `fix/`
pull request to its round, and the revert count. `goal.md`,
"Exclusions", says why.

2026-11-11. The human merged PR #214 and PR #215. The round 1 record of
`lean-context` queued one item for this goal: the stale pointer at
`Sources/KittermCLI/KittermMain.swift:310`.
