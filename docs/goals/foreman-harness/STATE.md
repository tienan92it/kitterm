# STATE: foreman-harness

- Status: active
- Round: 1 of 3 in this budget (first budget; round 1 done)
- Rounds total: 1
- Last floor: green (2026-09-10, round 1 after)
- Updated: 2026-09-10

## Queue

1. `skill-drops-curl` (capability 2)
2. `nearest-git-wins` (capability 3)
3. `four-loop-rules` (capability 4)

## Failures

None.

## Proposals waiting on the human

- `goal.md`, Frozen: its objective blames the MCP bridge for dropping the
  escape byte. Round 1 disproved that: the bridge and the route carry the
  byte, and the calling client strips it. The replacement paragraph is in
  `rounds/001.md`. The capability and the exclusions stand.
- `LOOP.md`, Labels: a crew's own helper session copies the round's four
  labels, so a scan by label counts it as a round session
  (`rounds/001.md`).

## Done

- `send-input-keys` (capability 1), round 1, `3ee32e7`. See
  `rounds/001.md`.

## Next action

Merge round 1, then round 2: `skill-drops-curl` from `plan.md` row 2;
proof: the `ForemanSkills` golden, no `curl` in the trust-dialog step,
and a live check that the installed skill answers a real dialog. It
needs `keys` on `main` and installed, so it follows the merge and a
`kitterm skills install`.
