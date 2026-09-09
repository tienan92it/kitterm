# STATE: goal-folders

- Status: active
- Round: 1 of 3 in this budget (round 1 done, round 2 open)
- Rounds total: 1
- Last floor: green (2026-09-09, round 1 after)
- Updated: 2026-09-09

## Queue

1. `summary-per-goal` (capability 2): round 2, running
2. `dashboard-per-goal` (capability 3)
3. `skill-and-docs` (capability 4)

## Failures

None.

## Proposals waiting on the human

- `LOOP.md` Authority: a test that pins a layout `goal.md` replaces is
  Propose, not Frozen. See `rounds/001.md`.

## Done

- `templates-and-cli` (capability 1): round 1, `8d59e4b`. See
  `rounds/001.md`.

## Direction

2026-09-09: the human opened this goal after `projects-and-knowledge`
was done, with the direction: each goal is one folder under
`docs/goals/`; status is tracked in the goal's `STATE.md`; a new goal is a
new folder; no done folder; the skill and the template must agree. The
foreman moved the finished package into its folder and rewrote
`docs/goals/LOOP.md` for the layout in this goal's first commit.

## Next action

Round 2: `summary-per-goal`. Send the capability 2 row from `plan.md`
with corpus request `04-goal-folders`; the summary route returns one
entry per goal folder, this repository's package is the fixture with one
done and one active goal.
