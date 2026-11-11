# Request: revamp the foreman and crew workflow

2026-11-10. The human asked: "Let's revamp and enhance the workflow of
foreman / crew. Don't get bias. Make a research of modern workflows.
Extract core ideas and advances. Give me suggestions to improve the
current workflow and how to enhance the output quality, consistent,
automatical, clean and efficient."

The foreman researched five tracks with no reference to the current
design, audited the 146 round records, and measured the first request of
six crew transcripts. The report is `01-research-report.md`. It ranks ten
changes. The human answered **"all changes"**.

## Where each change runs

Two crews never change the same files at the same time (change 10), so
the ten changes run in three goals and one chore, in this order.

| Change | Runs in | Starts |
|---|---|---|
| 1. Stop loading 178 KB of `AGENTS.md` into every crew | goal `lean-context`, round 1 | 2026-11-10 |
| 9. Prune `facts.md` with supersede markers | goal `lean-context`, the foreman's own edit | 2026-11-10 |
| 2. CI gates the crew cannot edit | chore `ci-release-gate`; the human edits `ci.yml` | 2026-11-10 |
| 4. Fix the measures | goal `round-commands`, round 1 | after `lean-context` merges |
| 5. `kitterm round open` and `kitterm round close` | goal `round-commands`, rounds 2 and 3 | after round 1 |
| 3. One rule in one place | goal `one-rule-one-place`, round 1 | after `round-commands` merges |
| 7, 8. Stalls, usage limits, deny rules | goal `one-rule-one-place`, round 2 | after round 1 |
| 6, 10. Review before ready, plan notes, file overlap | goal `one-rule-one-place`, round 3 | after round 2 |

`lean-context` runs first because every later round writes the
specification that it moves out of `AGENTS.md`. `round-commands` runs
before `one-rule-one-place` because the rules can then name the commands
once, and the procedure text is rewritten one time, not two.

The foreman writes `goal.md` and `plan.md` for each later goal when it
starts, from this table and the report; the human redirects on its pull
request.
