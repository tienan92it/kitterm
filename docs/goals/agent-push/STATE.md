# STATE: agent-push

- Status: active
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-09-11, round 3 after)
- Updated: 2026-09-11, round 3 closed

## Queue

1. `the-toggle` (capability 4)

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
- From round 3, and the second one needs the human. Capability 4 needs
  `GET /api/push/vapid` for `applicationServerKey`;
  `VAPIDKeys.publicKeyBase64URL` is ready and the route is not written,
  which capability 4 can do itself. Separately, `failed` still has no
  event on the feed, so a foreman polls rows for it; adding
  `command.failed` would change `AGENTS.md` and was outside round 3's
  authority.

## Done

- `secure-context` (capability 1), round 1, `35cef92`. See
  `rounds/001.md`. The goal does not stop: a phone gets a real secure
  context over the tailnet, with no certificate to install and nothing on
  the public internet.

- `subscriptions` (capability 2), round 2, `c005f49`. See
  `rounds/002.md`. `push.json` at `0600`, full grade only, one per
  endpoint, removable, and proved to survive both a restart and a
  takeover with real processes.

- `send-on-transition` (capability 3), round 3, `64ff789`. See
  `rounds/003.md`. The daemon sends one Web Push message per transition
  into `needs-input`, `needs-approval` and `failed`, and none for
  anything else. Dedupe per session and state, 4 per session per minute,
  and a 404 or 410 forgets the endpoint. The VAPID pair is its own
  `0600` file.

## Direction

2026-09-11: the human said continue, and chose Tailscale over a tunnel.
The tailnet already had HTTPS certificates enabled and the human's phone
was already a member, so the constraint capability 1 exists to settle was
answered on the machine rather than by a spike.

## Next action

Round 4: `the-toggle` from `plan.md` row 4, and it is the last
capability. A toggle on `/sessions` requests permission, subscribes, and
shows its state, hidden for a watch client. The notification's action
opens `/?session=<id>`. Proof: corpus request `01-phone-walks-away`, and
vitest over the model function.

It inherits three things from round 3. It needs `GET /api/push/vapid`,
which it should write, because `VAPIDKeys.publicKeyBase64URL` is ready.
It owns the first real send: round 3 contacted no real push service, and
`pushManager.subscribe` hung in headless Chromium for round 1, so this
round must get a real endpoint from a real browser. And the origin is
`https://<machine>.<tailnet>.ts.net` with no port, which round 1 settled.

After round 4 the goal's four completion conditions can be checked and
the goal closed.
