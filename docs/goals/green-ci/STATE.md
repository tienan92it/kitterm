# STATE: green-ci

- Status: done
- Round: 2 of 3 in this budget
- Rounds total: 2
- Last floor: green (2026-09-10, round 2 after; main green at dda4318)
- Updated: 2026-09-10, marked done

## Queue

Empty. Every capability in `plan.md` is done and all four completion
conditions in `goal.md` hold.

## Failures

None in the product. Two attempts at round 1 were killed by the host
machine, and round 2 was interrupted once by the machine sleeping; all
three are recorded in the round records and in `facts.md`.

## Proposals waiting on the human

- `LOOP.md` Budget: say how a round attempt the host machine kills is
  recorded, so it does not spend the budget (`rounds/001.md`).
- `ClaudePromptSubmitTests:182` waits two seconds for "first paint done";
  the real condition is `inputIsCanonical == false`. Round 2 could not
  widen the real `claude` binary's startup to prove the weakness and left
  the test alone (`rounds/002.md`).

## Done

- `paced-input-race` (1) and `takeover-race` (2), round 1, `9784fd2`.
  See `rounds/001.md`.
- `wait-helper-audit` (3), round 2, `7198ef1`. See `rounds/002.md`.

## Completion

All four conditions hold as of 2026-09-10.

1. Both waits are on real conditions: `inputIsCanonical == false` for the
   paced-input test, and `TakeoverController.admit` called three times
   for the takeover refusal, with no timing at all.
2. Twenty consecutive runs of each changed suite, and each race
   reproduced by a widening the fix survives: a `sleep` before `stty` for
   the paced-input race, and a spawn-helper shim that sleeps three
   seconds for the foreground gate. The human amended this condition on
   2026-09-10; `goal.md` carries the reason.
3. The floor was green each round, and the `test` job passed on PR #79
   and PR #81.
4. `main` is green after both merges, `d5eee71` and `dda4318`.

## Next action

None. The goal is done. Reopen with `Status: active` and a new queue when
a proposal above becomes a capability.
