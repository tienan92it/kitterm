# STATE: foreman-harness

- Status: active
- Round: 2 of 3 in this budget (second budget)
- Rounds total: 5
- Last floor: green (2026-09-10, round 5 after the foreman's command)
- Updated: 2026-09-10, round 5 closed after review

## Queue

Empty. All four capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

- `LOOP.md`, two parts of one gap. First, name the split-authority
  handoff: a capability whose deliverable spans the crew's files and a
  foreman-owned file is red at the crew's last commit by construction, so
  the round is not failed. Rounds 4 and 5 both were. The crew proposes a
  decision value `handoff` and a Floor line that reads "red at the crew's
  commit, green after the foreman's command". Second, say when a round's
  decision becomes final. The human requires a review before a merge, and
  the review runs after the round closes, so round 4 was recorded as done
  and then failed review on four defects. Either the record waits for the
  review, or the decision is provisional until it returns
  (`rounds/004.md`, `rounds/005.md`).

## Done

- `send-input-keys` (capability 1), round 1, `3ee32e7`. See
  `rounds/001.md`.
- `nearest-git-wins` (capability 3), round 2, `adcda4b`. See
  `rounds/002.md`. Taken out of order: capability 2 needed a release.
- `skill-drops-curl` (capability 2), round 3, `7d600c3`. See
  `rounds/003.md`.
- `four-loop-rules` (capability 4), rounds 4 and 5, `61b3f78` plus the
  foreman's commit. See `rounds/004.md` and `rounds/005.md`. Round 4
  wrote the four rules and closed the three proposals rounds 1, 2 and 3
  left open. Review then found four defects in it, and round 5 repaired
  them: the Authority table gains a fourth tier, **Chartered**, and the
  agreement check now compares whole rule sentences instead of four-word
  markers.

## Direction

2026-09-10: the human amended the objective's first paragraph after round
1 disproved it. The escape byte is lost in the calling MCP client, not in
kitterm. The capability and the exclusions stand.

2026-09-10: the human said continue after the first budget. Round 4 ran
in the second budget.

## Next action

Merge `goals/four-loop-rules-work` into `main` and check `main` green.
That is completion condition 5, and conditions 1 to 4 already hold, so the
merge finishes the goal. The review has run: two reviewers read round 4,
found four defects, and round 5 repaired all four, so the branch is ready.
Set `Status: done` after `main` is green. The proposal above waits on the
human and does not block the merge.
