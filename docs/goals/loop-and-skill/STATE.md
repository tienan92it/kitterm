# STATE: loop-and-skill

- Status: done
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-23, round 2 after: swift test and KittermCLITests exit 0, Linux build)
- Updated: 2026-09-23, round 2 closed, done

## Queue

Empty. Both capabilities are on the branch.

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `the-skill-holds-the-procedure` (capability 2), round 2, PR #149. See `rounds/002.md`. The skill 572 → 445 lines; the
  two files share no heading, where thirteen were shared at the start.
- `loop-holds-the-contract` (capability 1), round 1, PR #149. See `rounds/001.md`. `LOOP.md` 367 → 326 lines with a
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

None. Two rounds. Merge the PR; a release carries the new template and
the new skill to `kitterm goal new` and `kitterm skills install`.
