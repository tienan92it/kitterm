# STATE: projects-and-knowledge

- Status: waiting
- Round: 3 of 3 in this budget (second budget spent: rounds 4, 5, 6)
- Rounds total: 6
- Last floor: green (2026-09-08, round 6 after)
- Updated: 2026-09-08, after the v0.23.0 release

## Queue

1. `dogfood` (capability 6)

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
  `goals/knowledge-on-dashboard` at `61a7c45`, not pushed. See
  `rounds/006.md`.

## Merged and released (2026-09-08)

PRs #70 to #75 squash-merged into `main` bottom up (`b6f8862` to
`a64908e`). Tag `v0.23.0`, release run green, six assets. The daemon on
the foreman's machine upgraded in place; the three skills installed from
the binary; the kitterm project registered with `kitterm project add`.
Two lessons in `facts.md`: a stacked PR closes when its base branch is
deleted, and a merge of `main` into a stacked branch can re-add what the
branch removed.

## Next action

Direction decision by the human: continue, redirect, or stop. Before any
push of `goals/knowledge-on-dashboard`: the review gate (security on the
knowledge route, daemon, dashboard accessibility), then a fix round if it
finds should-fix items, then push and one PR to `main`. On "continue"
after that: `dogfood` (capability 6), the last item, which proves
completion condition 4 with a second registered project.
