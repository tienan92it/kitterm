# STATE: proxy-is-a-boundary

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-24, round 1 after: swift test 875, KittermDaemonTests 691, Linux build)
- Updated: 2026-09-24, round 1 closed

## Queue

1. `the-daemon-refuses-the-combination` (capability 2), and with it the
   two findings of round 1: `/api/lan` hands a proxied request both
   tokens, and a typo in `--trusted-host` fails open silently.

## Failures

None.

## Proposals waiting on the human

None.

## Done

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

Round 2, `the-daemon-refuses-the-combination`, on the same branch.
