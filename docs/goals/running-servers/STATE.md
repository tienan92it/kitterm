# STATE: running-servers

- Status: done
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-10-13, round 3 after: vitest 1809, swift test 1225, PR CI on a4ad1a2)
- Updated: 2026-10-13, round 3 done; the goal waits for the human's merge of PR #192

## Queue

None.

## Failures

None.

## Proposals waiting on the human

None. 2026-10-13: the human approved the frames at 852dddb and the
`●` mark (`corpus/01-approved-design.md`).

## Done

- `servers-section`, round 3, PR #192. See `rounds/003.md`. SERVERS
  on `/sessions`, the environment rule, and a timeout as unknown.
- `servers-design`, round 2, PR #192. See `rounds/002.md`. SERVERS
  in `Sessions 1200`, `Sessions 390` and `Sessions components`.
- `servers-route`, round 1, PR #192. See `rounds/001.md`.
  `GET /api/servers` lists the listening servers, who started each,
  its project and whether it answers HTTP.

## Next action

None. The human merges PR #192; the foreman releases, upgrades, and
checks the section's words on the live page. Reopen with a new
`goal.md` line or a chore on this surface.
