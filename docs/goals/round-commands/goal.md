# Goal: the round's bookkeeping is two commands

## Objective

One round asks the foreman for about 30 actions, and many of them are
deterministic: the worktree, the branch, the draft pull request, the five
labels, the cost line, the record header, the `STATE.md` fields. The
foreman wrote wrong pull request numbers in five records and back-filled
cost lines once (`corpus/00-request.md`, changes 4 and 5). The records
also mislead: the parser counts a `## Correction` heading that says
"None" as a correction, 17 times in 146 rounds, and the ledger holds no
foreman cost.

After this goal, `kitterm round open` does every step before the crew's
prompt, and `kitterm round close` does every step after the crew's
`DONE` note that needs no judgment. The foreman writes only the gap, the
decision, the effects and the reflection. A correction counts only when
its section says one happened, and a record names what the foreman
itself cost.

## Exclusions

- The procedure text stays as it is. `LOOP.md` outside "Parsed shapes",
  the foreman skill and `docs/foreman.md` belong to the goal
  `one-rule-one-place`, which then names the two commands once.
- No daemon route and no orchestration logic in the daemon. Both
  commands live in the CLI and use the routes that exist.
- Neither command merges, force-pushes, marks a pull request ready, or
  answers a dialog.
- No link from a later `fix/` pull request back to its round, and no
  revert count. The report says these measures need weeks of data; the
  foreman proposes them after `one-rule-one-place`.
- No change to the decision vocabulary (`done`, `failed`, `propose`).

## Charter

The human approved changes 4 and 5 on 2026-11-10 with the words "all
changes" (`corpus/00-request.md`). That approval charters the rounds of
this goal to:

- replace an assertion that pins a `## Correction` heading alone as a
  correction, so that it pins the new rule;
- add to "Parsed shapes" of `LOOP.md` and of `examples/goals/LOOP.md`
  (with `GoalsTemplates` and its hash history) the lines the new
  commands write, and nothing else in those files.

## Completion condition

All seven hold on the goal's branch:

1. A record whose `## Correction` section is absent, empty, or starts
   with "None" (any case, after list marks and spaces) has
   `correction: false` on `GET /api/projects/<id>/knowledge`. Any other
   section text gives `true`. A test pins each case.
2. `Sources/KittermCLI/KittermMain.swift` names no section of
   `AGENTS.md` that `AGENTS.md` no longer holds.
3. `kitterm round open` on a scratch repository with a bare remote
   creates the worktree and the branch, writes the queue line with
   `, PR #N.`, and spawns one session with the labels `crew`, `goal`,
   `round`, `task` and `pr`. It prints the session id, the worktree, the
   branch, the pull request number, the round number and the base sha,
   and `--json` prints the same as one object. A test proves this with a
   fake `gh` and a scratch daemon.
4. A second `kitterm round open` for a goal with a live crew session
   exits non-zero and changes nothing. A later round of a goal keeps the
   branch, the worktree and the pull request.
5. `kitterm round close` archives the round's sessions, reads each bill
   with a retry until the bill lands or a stated timeout ends, and writes
   `rounds/NNN.md` with the full header (`Goal`, `Started`, `Sessions`,
   `Archives`, `Base`, `Result`, one `Cost` line per session) and the six
   sections, each holding a marker the foreman replaces. It updates the
   five bullets of `STATE.md` and moves the queue item to `## Done`.
   `KnowledgeSummary` and `GoalLedger` read the record with no change to
   either parser. A test proves each field.
6. `kitterm round close --commit` refuses while a marker remains, and
   else makes one commit of the goal's folder and pushes it.
7. The record's header carries one `- Foreman:` line: the estimate of
   the foreman's own turns between the round's start and its end, from
   the foreman's transcript, priced by `ModelPricing`. The `Cost` parsers
   do not count that line. `swift test` is green and the pull request's
   `ci.yml` run is green.
