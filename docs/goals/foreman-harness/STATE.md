# STATE: foreman-harness

- Status: active
- Round: 1 of 3 in this budget (second budget)
- Rounds total: 4
- Last floor: green (2026-09-10, round 4 after the foreman's patch)
- Updated: 2026-09-10, round 4 closed

## Queue

Empty. All four capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

- `LOOP.md`: name the split-authority handoff. A capability whose
  deliverable spans the crew's files and a foreman-owned file cannot be
  green in one commit, so its floor is red at the crew's last commit by
  construction. The round is not failed. The crew delivers the command
  that makes the change plus the evidence that the command is right; the
  foreman runs it and the floor goes green (`rounds/004.md`).

## Done

- `send-input-keys` (capability 1), round 1, `3ee32e7`. See
  `rounds/001.md`.
- `nearest-git-wins` (capability 3), round 2, `adcda4b`. See
  `rounds/002.md`. Taken out of order: capability 2 needed a release.
- `skill-drops-curl` (capability 2), round 3, `7d600c3`. See
  `rounds/003.md`.
- `four-loop-rules` (capability 4), round 4, `2c0370e` plus the foreman's
  commit. See `rounds/004.md`. It closed the three proposals rounds 1, 2
  and 3 left open.

## Direction

2026-09-10: the human amended the objective's first paragraph after round
1 disproved it. The escape byte is lost in the calling MCP client, not in
kitterm. The capability and the exclusions stand.

2026-09-10: the human said continue after the first budget. Round 4 ran
in the second budget.

## Next action

Merge `goals/four-loop-rules-work` into `main` and check `main` green.
That is completion condition 5, and conditions 1 to 4 already hold, so the
merge finishes the goal. Set `Status: done` after `main` is green. Run the
review skill before the merge, as the human requires. One proposal above
waits on the human and does not block the merge.
