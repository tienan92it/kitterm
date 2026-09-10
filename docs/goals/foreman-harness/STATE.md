# STATE: foreman-harness

- Status: active
- Round: 3 of 3 in this budget (first budget spent: rounds 1, 2, 3)
- Rounds total: 3
- Last floor: green (2026-09-10, round 3 after)
- Updated: 2026-09-10, objective amended

## Queue

1. `four-loop-rules` (capability 4)

## Failures

None.

## Proposals waiting on the human

- `LOOP.md`, Labels: a crew's own helper session copies the round's four
  labels, so a scan by label counts it as a round session
  (`rounds/001.md`).
- `plan.md` capability 3: the row does not name the
  registered-root-inside-a-checkout case the code now carries
  (`rounds/002.md`).
- `LOOP.md` Authority: an assertion that pins the text of a document a
  round is chartered to rewrite is Propose, not Frozen, when the goal's
  own completion condition requires the change. Three rounds have hit
  this family now (`rounds/003.md`).

## Done

- `send-input-keys` (capability 1), round 1, `3ee32e7`. See
  `rounds/001.md`.
- `nearest-git-wins` (capability 3), round 2, `adcda4b`. See
  `rounds/002.md`. Taken out of order: capability 2 needed a release.
- `skill-drops-curl` (capability 2), round 3, `7d600c3`. See
  `rounds/003.md`.

## Direction

2026-09-10: the human amended the objective's first paragraph after round
1 disproved it. The escape byte is lost in the calling MCP client, not in
kitterm. The capability and the exclusions stand.

## Next action

The budget is spent after three rounds, so this goal needs a direction
check. Capability 4, `four-loop-rules`, is the only item left and it now
carries four proposals of its own to fold in. On continue: `skill-drops-curl` from `plan.md` row 2;
proof: the `ForemanSkills` golden, no `curl` in the trust-dialog step,
and a live check that the installed skill answers a real dialog. It
needs `keys` on `main` and installed, so it follows the merge and a
`kitterm skills install`.
