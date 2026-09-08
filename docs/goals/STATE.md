# STATE: projects-and-knowledge

- Status: active
- Round: 2 of 3 in this budget (second budget; rounds 4 and 5 done)
- Rounds total: 5
- Last floor: green (2026-09-08, round 5 after)
- Updated: 2026-09-08

## Queue

1. `knowledge-on-dashboard` (capability 5), branch off
   `goals/review-fixes`
2. `dogfood` (capability 6)

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
- Watch-grade access to `GET /api/projects/<id>/knowledge/<path>`. The plan
  recommends readable, the same class as a cwd. Decide before capability 5.
  The security review notes `GET /api/projects` already answers at watch
  grade while `/api/profiles` is full-only; record the choice either way.

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

## Next action

Push the six branches and open the PRs in order, each based on the
previous: `goals/knowledge-base` to `main`, then `goals/project-identity`,
`goals/dashboard`, `goals/scaffold-and-docs`, `goals/goal-loop-skill`,
`goals/review-fixes`. Merge and release wait for the human. Then round 6:
`knowledge-on-dashboard` off `goals/review-fixes`, after the human decides
watch-grade access to the knowledge route.
