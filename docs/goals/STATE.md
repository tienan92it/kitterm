# STATE: projects-and-knowledge

- Status: active
- Round: 1 of 3 in this budget (second budget; round 4 done)
- Rounds total: 4
- Last floor: green (2026-09-08, round 4 after)
- Updated: 2026-09-08

## Queue

1. `review-fixes`: the should-fix findings of the review gate, on a branch
   off `goals/goal-loop-skill`. Starts when all four reviews are in.
2. `knowledge-on-dashboard` (capability 5)
3. `dogfood` (capability 6)

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
- reuse and simplicity: running.
- dashboard accessibility: running.

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
- `plan.md`: add a corpus request for capabilities 3 and 4 before the next
  budget. See `rounds/003.md`.
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
  `97fa22e`, not pushed. See `rounds/004.md`.

## Next action

Wait for the reuse and accessibility reviews. Collect the four reports,
dedupe, rank. Then round 5: `review-fixes` in one crew session on branch
`goals/review-fixes` off `goals/goal-loop-skill`, with the ranked
should-fix list as the prompt and each fix proven by a test. After round
5 the stack is ready for push and PRs in order: `goals/knowledge-base`,
`goals/project-identity`, `goals/dashboard`, `goals/scaffold-and-docs`,
`goals/goal-loop-skill`, `goals/review-fixes`.
