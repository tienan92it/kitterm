# STATE: proxy-is-a-boundary

- Status: done
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-25, round 2 after: swift test 886, Linux build)
- Updated: 2026-09-25, PR #155 merged and v0.32.0 released

## Queue

Empty.

## Failures

- Round 2 stopped overnight on the crew's model usage limit, nine
  minutes in. No budget spent: the foreman saved the uncommitted work
  as `38f65af` and the held session resumed the next day with its
  context intact. See `rounds/002.md`.

## Proposals waiting on the human

None.

## Done

- `the-daemon-refuses-the-combination` (capability 2), round 2,
  `0152915`, PR #155. See `rounds/002.md`. Three holes closed, one of
  them a privilege escalation in the recommended configuration.
- `the-three-configurations` (capability 1), round 1, `280be50`. See
  `rounds/001.md`. Four tests over real sockets; the bypass is on the
  record with its verbatim responses, and two findings are worse than
  the proposal said.

## Direction

2026-09-24: the human asked what was next and the foreman named this,
the only open item that can hurt them. It was measured during
`agent-push` round 1 and parked as a proposal on a goal that then went
done, where it sat. A proposal that names an authorization bypass does
not belong in a done goal's list; it belongs in a goal of its own.

## Next action

None. Two rounds. PR #155 merged as `72b8352` and v0.32.0 carries the
refusal and the escalation fix. Reopen with a new queue item and
`Status: active`.
