# STATE: loop-and-skill

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-23, round 1 after: swift test 860, KittermCLITests 117, Linux build)
- Updated: 2026-09-23, round 1 closed

## Queue

1. `the-skill-holds-the-procedure` (capability 2), and with it the
   three leftovers of round 1: the intro's line 3, the two references
   to the now-absent `One round` and `Reports`, and where "commit after
   every round" belongs.

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `loop-holds-the-contract` (capability 1), round 1, `48f712b` and
  `dc3f26f`. See `rounds/001.md`. `LOOP.md` 367 → 326 lines with a
  `Parsed shapes` section; the procedure left for the skill.

## Direction

2026-09-23: the human asked why the rules sit in `LOOP.md` at all, and
whether the foreman skill, `LOOP.md` and `facts.md` are consistent or
duplicated. The foreman measured: thirteen headings appear in both
`LOOP.md` and the skill, the skill's ten record-shape sections name no
kitterm tool, and only `Authority` is substantially project-specific.
The human asked for the split to be organised on hard rules against
optional ones. That is `goal.md`'s four tiers: parsed, hard, procedure,
guidance. Tiers 1 and 2 are the project's contract; tiers 3 and 4 are
the machine's procedure.

## Next action

Round 2, `the-skill-holds-the-procedure`, on the same branch.
