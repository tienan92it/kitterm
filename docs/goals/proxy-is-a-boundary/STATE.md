# STATE: proxy-is-a-boundary

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-24, round 1 after: swift test 875, KittermDaemonTests 691, Linux build)
- Updated: 2026-09-24, round 2 stopped on a usage limit, its session held

## Queue

1. `the-daemon-refuses-the-combination` (capability 2), and with it the
   two findings of round 1: `/api/lan` hands a proxied request both
   tokens, and a typo in `--trusted-host` fails open silently.

## Failures

- Round 2 stopped nine minutes in: `You've reached your Fable limit`.
  The session `DE67ECB7-84F8-42AF-BDF3-17D3E5E66477` is held at its
  prompt with the work unwritten to git — the `/api/lan` grade fix and
  the `AGENTS.md` edits were in progress. Nothing is committed. Not a
  spent round: the budget and the queue item stay where they are.
  Resume the same session when the limit resets, or respawn with the
  plan and this round's correction.

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

Resume round 2 when the human's Fable limit resets. The crew's approved
plan and the foreman's correction are both in the session's history;
`rounds/001.md` holds the measurement it works from. The correction
added the escalation fix and replaced the launchd-loop answer with a
refusal in `kitterm upgrade`.
