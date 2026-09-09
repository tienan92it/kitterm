# STATE: green-ci

- Status: active
- Round: 1 of 3 in this budget (round 1 done)
- Rounds total: 1
- Last floor: green (2026-09-09, round 1 after; main green at d5eee71)
- Updated: 2026-09-09

## Queue

1. `wait-helper-audit` (capability 3): `SessionRegistryTests` and
   `InputEnterKeyTests` hold the same "not the shell" gate.

## Failures

None in the product. Two attempts at round 1 were killed by the host
machine, which is recorded in `rounds/001.md` and in `facts.md`.

## Proposals waiting on the human

- `goal.md` completion condition 2 names the method this goal abandoned:
  "20 consecutive local runs under a parallel load that keeps every core
  busy". That load killed the daemon three times and would have accepted
  a wrong fix; the loop replaced it with deterministic widening, which
  caught that wrong fix. `goal.md` is Frozen, so the condition stands as
  written and this goal is not complete until the human amends it.
  Proposed wording: "Each test passes 20 consecutive local runs, and the
  race it held is reproduced by a widening that the fix then survives."
  See `rounds/001.md`.
- `LOOP.md` Budget: say how a round attempt the host machine kills is
  recorded, so it does not spend the budget (`rounds/001.md`).

## Done

- `paced-input-race` (1) and `takeover-race` (2), round 1, `9784fd2`.
  See `rounds/001.md`.

## Next action

Two things, in either order. The human amends completion condition 2 in
`goal.md`, or rejects the change and the loop re-measures under load on a
machine that can take it. Round 2 runs `wait-helper-audit`.

Conditions met so far: 1 (both waits are on real conditions), 3 (the
`test` job passed on PR #79), 4 (`main`'s run after the merge, `d5eee71`,
is green: `test` and `linux-build` both pass). Condition 2 is met only in
its spirit, by 20 clean runs plus a widening the fix survives.
