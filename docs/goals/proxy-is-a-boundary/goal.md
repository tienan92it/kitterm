# Goal: a reverse proxy cannot inherit loopback's trust

## Objective

Today it can. With `--lan` set and no `--trusted-host`, a request that
arrives through a reverse proxy on loopback is read as the local human:
`GET /api/sessions` answers 200 at full grade with no token. Behind
`tailscale serve` that is every device on the tailnet, with the power
to spawn a shell and type into one when `--agent-control` is on. The
token grades and `--agent-control` are both defeated by two flags that
look independent.

`AccessPolicy.decide` already refuses that inheritance when the request
names a trusted host: `viaTrustedHost` exists exactly so a proxy can be
a boundary. The hole is the case where the operator never named one, so
nothing tells the daemon that a proxy is in front of it.

After this goal, that combination cannot silently grant full access. A
person who runs it either names their public host, or the daemon
refuses to start and says why.

## Exclusions

- No change to the loopback-only default, which is what nearly every
  user runs and is not affected.
- No change to what a token grade may do once it is decided.
- No new configuration file and no network sniffing: the daemon must
  decide from its own flags and the request in hand.
- This goal does not add authentication to the proxy hop. A proxy that
  wants to pass identity through is a different goal.

## The measurement to reproduce first

Round 1 of `agent-push` measured three configurations and the foreman
confirmed the branch in `AccessPolicy.decide`. The first round of this
goal repeats that measurement before changing anything, so the fix is
aimed at a failure that is on the record twice:

| Configuration | `GET /api/sessions` from a loopback proxy | Expected after |
|---|---|---|
| default, no `--lan` | rejected, `loopback only` | unchanged |
| `--lan` with `--trusted-host <name>`, request names that host | needs a token | unchanged |
| `--lan`, no `--trusted-host` | **200 at full grade, no token** | refused |

## Completion condition

All five hold on a build from `main`:

1. With `--lan` and no `--trusted-host`, the daemon refuses to start
   and its message names both flags and the fix.
2. The refusal cannot be bypassed by a request's headers: a test drives
   the three configurations above over real sockets and pins each
   outcome.
3. The loopback-only default and the `--trusted-host` configuration
   behave exactly as they do today, pinned by tests that fail if either
   changes.
4. `AGENTS.md`'s Security section and `docs/architecture.md` say what
   the combination does and why, in the words the daemon prints.
5. A person upgrading into this who was running the unsafe combination
   gets a message they can act on, not a stack trace; the round record
   quotes it.

The floor (`swift test`, the Linux docker pipe, `swift run KittermBench
interactive-echo` under 50 ms p95) is green at every step.

## What is not exposed today

The live daemon runs without `--lan`, and `tailscale serve status`
reported no serve configuration when `agent-push` round 1 measured it.
This goal closes a hole that is reachable by a configuration the human
does not currently use.
