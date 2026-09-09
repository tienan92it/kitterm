# STATE: goal-folders

- Status: waiting
- Round: 3 of 3 in this budget (budget spent: rounds 1, 2, 3)
- Rounds total: 3
- Last floor: green (2026-09-09, round 3 after)
- Updated: 2026-09-09

## Queue

1. `skill-and-docs` (capability 4)

## Failures

None.

## Proposals waiting on the human

- `LOOP.md` Authority: a test that pins a layout `goal.md` replaces is
  Propose, not Frozen. See `rounds/001.md`.

## Done

- `templates-and-cli` (capability 1): round 1, `8d59e4b`. See
  `rounds/001.md`.
- `summary-per-goal` (capability 2): round 2, `0227aa5`. See
  `rounds/002.md`.
- `dashboard-per-goal` (capability 3): round 3, `01a6ad5`. See
  `rounds/003.md`.

## Direction

2026-09-09: the human opened this goal after `projects-and-knowledge`
was done, with the direction: each goal is one folder under
`docs/goals/`; status is tracked in the goal's `STATE.md`; a new goal is a
new folder; no done folder; the skill and the template must agree. The
foreman moved the finished package into its folder and rewrote
`docs/goals/LOOP.md` for the layout in this goal's first commit.

## Next action

Direction decision by the human: continue, redirect, or stop. On
"continue": round 4 `skill-and-docs`, the last capability, which makes
the installed skill read every goal folder; until it lands the standing
foreman still reads one `docs/goals/STATE.md`, which this repository no
longer has. Then the review gate on `main...goals/goal-folders`, the
fixes, push, and one PR. The human asked on 2026-09-09 why `facts.md`
and `LOOP.md` sit outside a goal; the foreman answered that they
describe the repository, and offered an optional per-goal `facts.md` in
round 4 if wanted.
