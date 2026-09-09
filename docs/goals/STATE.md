# STATE: projects-and-knowledge

- Status: active
- Round: 2 of 3 in this budget (third budget; round 8 open)
- Rounds total: 7
- Last floor: green (2026-09-09, round 7 after)
- Updated: 2026-09-09

## Queue

1. `dogfood` (capability 6): round 8, running

## Failures

None. One pre-existing flake recorded in `rounds/001.md` (runtime
candidate, `LiveTakeoverTests`).

## Review gate (2026-09-08, before any push)

Diff `main...goals/scaffold-and-docs`, four dimensions, static and
read-only. Reports under the job's `review/` directory.

- security: blocking 0, should-fix 1, nit 4. The should-fix is the `.git`
  walk and the `projects.json` reload on the NIO event loop.
- daemon performance and correctness: blocking 0, should-fix 4, nit 5. The
  same event-loop finding, the store lock holding file I/O the loop waits
  on, the archive list re-walking every record twice per tick, and the
  dashboard signature repainting every tick while a session prints.
- reuse and simplicity: blocking 0, should-fix 6, nit 9. Unread
  aggregates on `GET /api/projects`, two test fixtures repeated, the state
  tree and the resolution rule stated in several places, `LOOP.md` in
  three copies.
- dashboard accessibility: blocking 1, should-fix 11, nit 12. The row menu
  is clipped at 390 px on the last row of a card; repaints drop focus; no
  live region; shared button names; faint and state-label text under
  4.5:1 on most themes; the sticky strip has no height cap.
- ranked and deduped list: the job's `review/ranked.md`; R0 blocking, R1
  to R10 required, nits optional, six items left with reasons.

## Proposals waiting on the human

- `plan.md` capability 1, the resolution rule: let the nearest `.git` win
  over a registered parent prefix. See `rounds/002.md`. Decide before the
  capability 1 PR merges.
- `plan.md` capability 3: "names all 15 tools" becomes "16". See
  `rounds/003.md`.
- `LOOP.md` Authority: a count pin or a golden list in an existing test is
  Propose, not Frozen, when the change adds and removes nothing. See
  `rounds/001.md`.
- `LOOP.md` One round step 2: spawn with no input, floor in the shell, then
  `claude`. See `rounds/004.md`.
- `LOOP.md` Labels: `resumed-from` is an archive id or the pane's previous
  id. See `rounds/004.md`.
- `LOOP.md` exists three times (`docs/goals/`, `examples/goals/`,
  `GoalsTemplates.swift`) with no test between the instance and the
  template (reuse review 6). Either the instance keeps only the tiers and
  points at the template for the procedure, or a test pins the shared
  lines.
- The resolution rule folds a submodule into its superproject (daemon
  review 7). Decide with the nearest-`.git` proposal.
- `plan.md`: add a corpus request for capabilities 3 and 4 before the next
  budget. See `rounds/003.md`.
- `plan.md` capability 1: the row names counts on `GET /api/projects`; the
  route returns identity only since round 5.
- `LOOP.md`: commit to the base branch before sending a round's prompt;
  run a review gate on the stack before a push. See `rounds/005.md`.
- `tokens.css`: raise the `--ui-text-muted` mix; under 4.5:1 on 10 of 16
  themes. Outside this goal's diff.
- `LOOP.md` Round record and state shape: the `- Status:` and `- Round: N
  of M` lines and the `## Next action` heading of `STATE.md` are an
  interface since round 6; the summary route parses them. See
  `rounds/006.md`.
- Prune the decided items from this list; the card counts every bullet.
- `LOOP.md`: a new element on the page adds its contrast pair to
  `theme-contrast.test.ts` in the same round; a link that opens a served
  file is checked on a browser that does not render the file's type. See
  `rounds/007.md`.
- Decided 2026-09-08 by "continue" with the plan's recommendation: the
  knowledge route answers at watch grade, the same class as a cwd and as
  `GET /api/projects`. Record the choice in AGENTS.md "Security".

## Done

- `project-identity` (capability 1): round 1, `goals/project-identity` at
  `9bb6d8b`, not pushed. See `rounds/001.md`.
- `dashboard` (capability 2): round 2, `goals/dashboard` at `b7bd5a6`, not
  pushed. See `rounds/002.md`.
- `scaffold-and-docs` (capability 3): round 3, `goals/scaffold-and-docs`
  at `332e096`, not pushed. See `rounds/003.md`.
- `goal-loop-skill` (capability 4): round 4, `goals/goal-loop-skill` at
  `97fa22e`. See `rounds/004.md`.
- `review-fixes`: round 5, `goals/review-fixes` at `f772b56`. See
  `rounds/005.md`.
- `knowledge-on-dashboard` (capability 5): round 6,
  `goals/knowledge-on-dashboard` at `61a7c45`. See `rounds/006.md`.
- `review-fixes-2`: round 7, the same branch at `1e9cee3`. See
  `rounds/007.md`.

## Merged and released (2026-09-08)

PRs #70 to #75 squash-merged into `main` bottom up (`b6f8862` to
`a64908e`). Tag `v0.23.0`, release run green, six assets. The daemon on
the foreman's machine upgraded in place; the three skills installed from
the binary; the kitterm project registered with `kitterm project add`.
Two lessons in `facts.md`: a stacked PR closes when its base branch is
deleted, and a merge of `main` into a stacked branch can re-add what the
branch removed.

## Direction

2026-09-09: the human said "continue" and "review and push" after round
6. Third budget opens. The review gate runs on
`main...goals/knowledge-on-dashboard` first (security, daemon, dashboard
accessibility); a fix round follows if it finds should-fix items; then
push and one PR to `main`. `dogfood` starts after the push.

## Review gate 2 (2026-09-09, on round 6's branch)

- security: blocking 0, should-fix 2, nit 4. The read opens the unchecked
  path after the checks; the discovered-project fallback serves any repo a
  pane visited.
- daemon: blocking 0, should-fix 3, nit 7. The poll waits on every summary
  fetch; the latest record is re-derived from its number; a third copy of
  the write path.
- accessibility: blocking 0, should-fix 9, nit 6. The record link
  downloads on Chrome and Firefox; new links lose focus on repaint; a
  proposal cannot be dismissed; the next action is cut; two contrast pairs
  outside the test; two numbers share the word "round".
- ranked and deduped: the job's `review2/ranked.md`, F1 to F11 required.

## Pull request

- #76 `goals/knowledge-on-dashboard` to `main`: the knowledge routes and
  the card, with review gate 2's fixes. Merge waits for the human.

## Next action

Round 8 `dogfood`, corpus request 03: two fixture projects registered
(`alpha`, a Python `wc2` goal with three queue items and a green floor;
`beta`, a package at `Status: waiting`); a standing foreman in its own
pane labelled `crew:foreman` on the installed `foreman-loop` skill, told
"Run every active goal until its budget is spent." The record of this
round goes on branch `goals/dogfood`.
