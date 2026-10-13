# STATE: running-servers

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-10-13, round 1 after: swift test 1212, PR CI on 486eb6d)
- Updated: 2026-10-13, round 1 done; the human chose draft A

## Queue

1. `servers-design` (capability 2), PR #192.
2. `servers-section` (capability 3), PR #192. It also makes a
   probe timeout count as unknown, asked again (`rounds/001.md`, Gap).

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `servers-route`, round 1, PR #192. See `rounds/001.md`.
  `GET /api/servers` lists the listening servers, who started each,
  its project and whether it answers HTTP.

## Next action

Round 2: `servers-design` from `plan.md` row 2: draft A of
`corpus/01-approved-design.md` into `design/sessions.pen`, headless,
with the phone layout, the mark and the empty sentence; the human
approves the frames.
