# The human's request

2026-10-06, in the foreman's pane:

> research about clef (https://developers.cloudflare.com/workers-ai/models/clef/)
> from Cloudflare. How can we apply it to the kitterm

The foreman's answer recommended rules first, a count of `unknown`, and
an opt-in Clef-flash fallback for `unknown` only, in the MCP bridge. The
assessment is the comment of 2026-10-07 on issue #171
(https://github.com/tienan92it/kitterm/issues/171#issuecomment-6031557365).

2026-10-07, the human's answer:

> add it to #171 and implement

## What Clef is (from the assessment)

`@cf/cloudflare/clef-flash` reads a `state` and up to 64 typed
`questions` (`noul`, `choice` with named `criteria`, `score`) and
answers a probability for every allowed option. Request, Workers AI
REST:

```
POST https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/ai/run/@cf/cloudflare/clef-flash
Authorization: Bearer <token>
{"model": "clef", "state": "...",
 "questions": {"state": {"type": "choice", "instructions": "...",
                         "criteria": {"prompt-empty": "...", ...}}}}
```

The answer holds `model`, `answers` (one per question id, with its
probabilities and the selected option) and `usage`. $0.09 per M input
tokens, median 39 ms, context 65,536 tokens. Workers AI says it does not
read, store or train on requests unless the account opts in to
fine-tuning.

## Rules the human accepted with the plan

- The daemon judges nothing: the tool and the fallback live in the MCP
  bridge (`KittermCLI`), beside `KittermScreen` (ADR 0001).
- With no configuration, nothing leaves the machine.
- A state that Clef gives is a hint, never a reason to type: the
  foreman reads the screen before it types on a Clef answer.
- No action is ever taken from a Clef answer alone: no dialog answer, no
  permission decision.
