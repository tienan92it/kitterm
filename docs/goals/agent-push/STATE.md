# STATE: agent-push

- Status: active
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-11, round 2 after)
- Updated: 2026-09-11, round 2 closed

## Queue

1. `send-on-transition` (capability 3)
2. `the-toggle` (capability 4)

## Failures

None.

## Proposals waiting on the human

- **`Sources/`: two flags combine into an authorization bypass.** With
  `--lan` set and no `--trusted-host`, a reverse proxy that connects from
  loopback is read as the local human, and `GET /api/sessions` answers
  `200` at full grade with no token. Behind `tailscale serve` that means
  the whole tailnet. It defeats the token grades and `--agent-control`.
  Round 1 measured all three configurations and the foreman confirmed the
  branch in `AccessPolicy.decide`. The proposal is to make the daemon
  refuse to start, or warn on every request, in that combination.
  **Nothing is exposed today**: the live daemon runs without `--lan` and
  `tailscale serve status` reports no serve config. See `rounds/001.md`.
- Three from round 2, none blocking. `AGENTS.md`'s HTTP API list does not
  name `POST` and `DELETE /api/push/subscriptions`. Capability 3 needs a
  VAPID key pair, which belongs in its own `0600` file rather than in
  `push.json`. Capability 4 may want `GET /api/push/subscriptions` for
  the toggle's state, which `plan.md` row 2 does not ask for.

## Done

- `secure-context` (capability 1), round 1, `35cef92`. See
  `rounds/001.md`. The goal does not stop: a phone gets a real secure
  context over the tailnet, with no certificate to install and nothing on
  the public internet.

- `subscriptions` (capability 2), round 2, `c005f49`. See
  `rounds/002.md`. `push.json` at `0600`, full grade only, one per
  endpoint, removable, and proved to survive both a restart and a
  takeover with real processes.

## Direction

2026-09-11: the human said continue, and chose Tailscale over a tunnel.
The tailnet already had HTTPS certificates enabled and the human's phone
was already a member, so the constraint capability 1 exists to settle was
answered on the machine rather than by a spike.

## Next action

Round 3: `send-on-transition` from `plan.md` row 3. On the `agent.status`
transitions into `needs-input`, `needs-approval` and `failed`, send one
message per subscription carrying the session name, the project and the
reason. Dedupe per session and state, rate-limit per session, drop a
subscription the endpoint answers `410` for, and do it off the event
loop.

Round 2 settled what capability 3 inherits. Removal is capability 3's to
call, through `PushSubscriptionStore.remove(endpoint:)`, the same call
`DELETE` uses. The VAPID key pair it needs goes in its own `0600` file,
not in `push.json`. The bench is a real gate for this goal, so round 3
must report p95.
