# STATE: running-servers

- Status: active
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-10-13, round 2 after: PR CI on 852dddb)
- Updated: 2026-10-13, round 2 done; the frames wait on the human

## Queue

1. `servers-section` (capability 3), PR #192. It also makes a
   probe timeout count as unknown, asked again (`rounds/001.md`, Gap).

## Failures

None.

## Proposals waiting on the human

- Approve the SERVERS frames of `design/sessions.pen` at 852dddb
  (`rounds/002.md`), and the row `listening | ● accent | a server
  row` for `design/foundation.md`.

## Done

- `servers-design`, round 2, PR #192. See `rounds/002.md`. SERVERS
  in `Sessions 1200`, `Sessions 390` and `Sessions components`.
- `servers-route`, round 1, PR #192. See `rounds/001.md`.
  `GET /api/servers` lists the listening servers, who started each,
  its project and whether it answers HTTP.

## Next action

Round 3: `servers-section` from `plan.md` row 3, once the human
approves the frames: the page draws SERVERS as the frames show, and a
probe timeout counts as unknown and is asked again.
