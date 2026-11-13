# Request: changes 3, 6, 7, 8 and 10 of the workflow revamp

2026-11-10. The human asked for a revamp of the foreman and crew
workflow, read the research report, and answered **"all changes"**. The
request, the routing of the ten changes and the report are in
`docs/goals/lean-context/corpus/00-request.md` and
`docs/goals/lean-context/corpus/01-research-report.md`. This goal does
not copy them.

This goal runs the last three rows of that routing table:

| Change | Round |
|---|---|
| 3. One rule in one place | 1 |
| 7. Stalls and usage limits; 8. deny rules | 2 |
| 6. Review before ready; 10. plan notes, the correction cap, file overlap | 3 |

2026-11-11. The human merged PR #216 (`round-commands`). Its records
queued four items for this goal:

- "Parsed shapes" of `LOOP.md` still says a correction is a heading
  (`round-commands/rounds/001.md`).
- The foreman no longer raises the `- Round:` bullet when a round
  opens; `kitterm round close` owns it (`rounds/003.md`).
- `round close --commit` must follow a green check on the head
  (`rounds/003.md`).
- A crew that waits on its own background job sends Claude Code's idle
  `needs-input`; the stall rule reads `screen_state` first
  (`lean-context/rounds/001.md`).
