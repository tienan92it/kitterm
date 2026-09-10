# STATE: agent-push

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-11, round 1 after)
- Updated: 2026-09-11, round 1 closed

## Queue

1. `subscriptions` (capability 2)
2. `send-on-transition` (capability 3)
3. `the-toggle` (capability 4)

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

## Done

- `secure-context` (capability 1), round 1, `35cef92`. See
  `rounds/001.md`. The goal does not stop: a phone gets a real secure
  context over the tailnet, with no certificate to install and nothing on
  the public internet.

## Direction

2026-09-11: the human said continue, and chose Tailscale over a tunnel.
The tailnet already had HTTPS certificates enabled and the human's phone
was already a member, so the constraint capability 1 exists to settle was
answered on the machine rather than by a spike.

## Next action

Round 2: `subscriptions` from `plan.md` row 2. `POST
/api/push/subscriptions` stores a Web Push subscription in
`~/.kitterm/push.json`, full grade only, one per endpoint, removable, and
the file is written `0600`. `DELETE` removes one. Proof: route tests for
the grades, the duplicate endpoint and the removal, and a watch token
answering 403.

Two things round 1 settled that capability 2 should assume. The origin is
`https://<machine>.<tailnet>.ts.net` with no port, so a subscription
outlives a daemon restart, a port change and a live upgrade, and
capability 2 does not need to handle re-subscription. `push.json` must
therefore persist across all three. Round 1 obtained no real push
endpoint: `pushManager.subscribe` hung in headless Chromium on the
permission prompt, so that proof belongs to capabilities 2 and 4.
