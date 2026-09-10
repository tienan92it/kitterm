# STATE: foreman-harness

- Status: active
- Round: 2 of 3 in this budget (first budget; rounds 1 and 2 done)
- Rounds total: 2
- Last floor: green (2026-09-10, round 2 after)
- Updated: 2026-09-10, objective amended

## Queue

1. `skill-drops-curl` (capability 2), unblocked by the v0.25.0 release
2. `four-loop-rules` (capability 4)

## Failures

None.

## Proposals waiting on the human

- `LOOP.md`, Labels: a crew's own helper session copies the round's four
  labels, so a scan by label counts it as a round session
  (`rounds/001.md`).
- `plan.md` capability 3: the row does not name the
  registered-root-inside-a-checkout case the code now carries
  (`rounds/002.md`).

## Done

- `send-input-keys` (capability 1), round 1, `3ee32e7`. See
  `rounds/001.md`.
- `nearest-git-wins` (capability 3), round 2, `adcda4b`. See
  `rounds/002.md`. Taken out of order: capability 2 needed a release.

## Direction

2026-09-10: the human amended the objective's first paragraph after round
1 disproved it. The escape byte is lost in the calling MCP client, not in
kitterm. The capability and the exclusions stand.

## Next action

Round 3: `skill-drops-curl` from `plan.md` row 2;
proof: the `ForemanSkills` golden, no `curl` in the trust-dialog step,
and a live check that the installed skill answers a real dialog. It
needs `keys` on `main` and installed, so it follows the merge and a
`kitterm skills install`.
