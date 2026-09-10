# Goal: kitterm reaches the human who walked away

## Objective

The daemon knows the moment a crew session needs a person: a
`Notification` hook makes it `needs-input`, a held `PermissionRequest`
makes it `needs-approval`, a non-zero exit makes it `failed`. Today that
knowledge reaches a person only while they are looking at `/sessions` or
reading a foreman's report. The standing foreman's promise, that you can
start a crew and walk away, is half true without it.

Issue #21. This closes it for the case that matters: a phone that has
opened the fleet view once receives a notification when a session needs
its human, and receives nothing when a session merely works or goes idle.

## Exclusions

- No third-party push service beyond the browser's own Web Push
  endpoint, and no account.
- No notification for a state a human cannot act on: `working`, `idle`,
  `completed` alone.
- No notification to a watch-grade client. A watch token exists to
  withhold the answer, so it does not get the question either.
- No change to the states themselves, or to the hooks that record them.
- No email, no SMS, no desktop agent.

## Completion condition

All five hold:

1. A phone that opened `/sessions` over the daemon's TLS listener and
   enabled notifications receives one within ten seconds of a session
   entering `needs-input`, `needs-approval`, or `failed`.
2. It receives nothing for `working`, `idle`, or `completed`, and nothing
   twice for one unchanged state.
3. A watch-grade client cannot subscribe, and a full-grade subscription
   is refused after its token is revoked.
4. Tapping the notification opens that session's pane.
5. The floor is green and `main` is green after the merge.
