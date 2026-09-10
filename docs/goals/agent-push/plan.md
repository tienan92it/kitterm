# Plan

## The floor

The floor of `foreman-harness`, unchanged. This goal touches the event
path, so KittermBench is a real gate here, not a formality.

## The constraint to settle first

Web Push needs a secure context: a service worker registers only over
HTTPS or on `localhost`. kitterm serves TLS on `port+1` with
`--tls-cert` and `--tls-key`. A phone on the LAN therefore reaches the
fleet view over that listener, or over a tunnel that terminates TLS. The
first capability settles which of those this goal supports and writes it
down; a plan that assumes the wrong one wastes the rest.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **The context, decided and documented.** Determine what a phone needs to register a service worker against this daemon: the TLS listener, a tunnel, or both. Write it in `docs/architecture.md` and in the goal record with the measurement that settled it. No code beyond a spike that is thrown away. | A phone registers a service worker against the daemon and the registration survives a reload, or the record says why it cannot and the goal stops for the human. |
| 2 | **A subscription the daemon keeps.** `POST /api/push/subscriptions` stores a Web Push subscription in `~/.kitterm/push.json`, full grade only, one per endpoint, removable. `DELETE` removes one. The file carries no secret beyond the endpoint's own keys and is written 0600. | Route tests for the grades, the duplicate endpoint, the removal; a watch token answers 403. |
| 3 | **The daemon sends one, and only when it should.** On the `agent.status` transitions into `needs-input`, `needs-approval` and `failed`, send one message per subscription, carrying the session name, the project, and the reason. Dedupe per session and state, rate-limit per session, and drop a subscription the endpoint rejects as gone. Off the event loop. | A test daemon with a fake endpoint: one message per transition, none for `working` or `idle`, none twice, and a 410 from the endpoint removes the subscription. Bench unchanged. |
| 4 | **The page asks, and says.** A toggle on `/sessions` requests permission, subscribes, and shows the state, hidden for a watch client. The notification's action opens `/?session=<id>`. | Corpus request `01-phone-walks-away`; vitest over the model function. |

Each capability depends on the one before it. Capability 1 may stop the
goal; that is its job.
