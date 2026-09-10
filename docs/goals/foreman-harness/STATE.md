# STATE: foreman-harness

- Status: active
- Round: 1 of 3 in this budget (first budget; round 1 done)
- Rounds total: 1
- Last floor: green (2026-09-10, round 1 after)
- Updated: 2026-09-10, objective amended

## Queue

1. `skill-drops-curl` (capability 2)
2. `nearest-git-wins` (capability 3)
3. `four-loop-rules` (capability 4)

## Failures

None.

## Proposals waiting on the human

- `LOOP.md`, Labels: a crew's own helper session copies the round's four
  labels, so a scan by label counts it as a round session
  (`rounds/001.md`).

## Done

- `send-input-keys` (capability 1), round 1, `3ee32e7`. See
  `rounds/001.md`.

## Direction

2026-09-10: the human amended the objective's first paragraph after round
1 disproved it. The escape byte is lost in the calling MCP client, not in
kitterm. The capability and the exclusions stand.

## Next action

Round 2: `skill-drops-curl` from `plan.md` row 2;
proof: the `ForemanSkills` golden, no `curl` in the trust-dialog step,
and a live check that the installed skill answers a real dialog. It
needs `keys` on `main` and installed, so it follows the merge and a
`kitterm skills install`.
