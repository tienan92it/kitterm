# STATE: green-ci

- Status: active
- Round: 1 of 3 in this budget (round 1 done)
- Rounds total: 1
- Last floor: green (2026-09-09, round 1 after)
- Updated: 2026-09-09

## Queue

1. `wait-helper-audit` (capability 3): `SessionRegistryTests` and
   `InputEnterKeyTests` hold the same "not the shell" gate.

## Failures

None in the product. Two attempts at round 1 were killed by the host
machine, which is recorded in `rounds/001.md` and in `facts.md`.

## Proposals waiting on the human

- `LOOP.md` Budget: say how a round attempt the host machine kills is
  recorded, so it does not spend the budget (`rounds/001.md`).

## Done

- `paced-input-race` (1) and `takeover-race` (2), round 1, `9784fd2`.
  See `rounds/001.md`.

## Next action

Push `goals/green-ci` and open one PR to `main`, so CI runs the two
fixed tests on the runner that failed them. Completion condition 4 needs
`main`'s next run after the merge to be green. Round 2,
`wait-helper-audit`, follows.
