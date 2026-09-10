# Request 01: the phone is told, once

Approved 2026-09-10. Frozen.

## Fixture

A daemon with `--agent-control` and TLS, reachable from a phone on the
same network. The phone has opened `/sessions` and enabled
notifications. Two crew sessions run `claude` with the hooks installed.

## Request

1. One session's agent sends a `Notification` hook, so it becomes
   `needs-input`.
2. The same session stays `needs-input` for a minute.
3. The other session runs a tool that raises a permission dialog, so it
   becomes `needs-approval`.
4. The first session's human answers it and the session returns to
   `working`, then `completed`.

## Expected behaviour

The phone receives one notification after step 1, naming the session and
the project, and nothing more during step 2. It receives a second after
step 3. It receives nothing for step 4. Tapping the first notification
opens that session's pane.

## Expected persistent effects

`~/.kitterm/push.json` holds one subscription, mode 0600. No message is
sent to a watch-grade client, and none is sent after the subscription is
removed.
