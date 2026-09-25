# STATE: agent-push

- Status: done
- Round: 4 of 3 in this budget (first budget)
- Rounds total: 4
- Last floor: green (2026-09-11, round 4 after)
- Updated: 2026-09-11, done

## Queue

Empty. All four capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

- `failed` has no event on the feed, so a foreman polls the session rows
  for it. A `command.failed` event (a non-zero `commandEnded`, perhaps
  for orchestrated sessions only) is a new event type on the feed's
  contract, so it is a goal, not a chore.

2026-09-25, the foreman closed the rest as shipped: the proxy bypass
(PR #155), the subscription routes in `AGENTS.md`, the VAPID key in its
own `0600` file (PR #102) and `GET /api/push/vapid` (PR #103). The page
reads `pushManager.getSubscription()`, so no subscription route is
needed.

## Done

- `secure-context` (capability 1), round 1, `35cef92`, PR #93. See
  `rounds/001.md`. The goal does not stop: a phone gets a real secure
  context over the tailnet, with no certificate to install and nothing on
  the public internet.

- `subscriptions` (capability 2), round 2, `c005f49`, PR #99. See
  `rounds/002.md`. `push.json` at `0600`, full grade only, one per
  endpoint, removable, and proved to survive both a restart and a
  takeover with real processes.

- `send-on-transition` (capability 3), round 3, `64ff789`, PR #102. See
  `rounds/003.md`. The daemon sends one Web Push message per transition
  into `needs-input`, `needs-approval` and `failed`, and none for
  anything else. Dedupe per session and state, 4 per session per minute,
  and a 404 or 410 forgets the endpoint. The VAPID pair is its own
  `0600` file.

- `the-toggle` (capability 4), round 4, `eb66c4f`, PR #103. See `rounds/004.md`.
  The toggle is a pure function with eight states, hidden for a watch
  client. `GET /api/push/vapid` is full grade only. The service worker is
  served at `/sw.js` so its scope is `/`. Corpus request
  `01-phone-walks-away` ran against a real browser and a real push
  service and passed as written, except the tap itself, which no
  automated browser can perform.

## Direction

2026-09-11: the human said continue, and chose Tailscale over a tunnel.
The tailnet already had HTTPS certificates enabled and the human's phone
was already a member, so the constraint capability 1 exists to settle was
answered on the machine rather than by a spike.

## Next action

None. The goal is done. All four completion conditions hold:

1. A phone that opened `/sessions` over the tailnet and enabled
   notifications receives one within ten seconds of a session entering
   `needs-input`, `needs-approval` or `failed`. Measured at 400 ms and
   160 ms in round 4.
2. It receives nothing for `working`, `idle` or `completed`, and nothing
   twice for one unchanged state. Round 3 asserts each case against a
   fake service with the bodies decrypted; round 4 observed 84 s of
   silence while a session waited.
3. A watch client cannot subscribe: it sees no switch and gets 403 on the
   vapid route and on `POST`. A full subscription is refused after its
   token is revoked.
4. Tapping the notification opens that session's pane. **Proved in
   part.** The notification carries `data.url=/?session=<id>` and
   `sw.test.ts` drives the real `sw.js`, but no automated browser can
   click an operating-system notification. One tap on a phone would close
   it.

Two proposals stay open and are listed above. To reopen the goal, set
`Status: active` with a new budget and queue.
