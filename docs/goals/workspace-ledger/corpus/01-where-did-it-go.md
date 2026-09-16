# Request 01: where did it go

Approved 2026-09-16. Frozen.

## Fixture

The human's real tree on 2026-09-16, which the reference image
`00-before-390.png` shows before this goal:

- Registered projects: `kitterm` under `/Users/antran/Workspace`, and
  `market-data-pipeline` and `nghenhan-mt5` under
  `/Users/antran/Workspace/NgheNhanTrading`. One discovered checkout,
  `trading-data-api`, beside them.
- `kitterm` holds ten goals, all `done`.
- `market-data-pipeline` holds `symbol-onboarding`, `active`, with a
  live crew on it, and `session-aware-sink-health`, `done`.
- `nghenhan-mt5` is registered with no goal folder.
- Seven live sessions: one foreman with `crew: foreman`, one crew with
  `goal: symbol-onboarding`, and five plain shells.
- A quota reading arrived from a statusline render four minutes ago:
  five-hour 24%, seven-day 27%, both resetting later today.
- Thirty days of daily cost, totalling $1,131.93, of which `kitterm` is
  $699.93.

## Request

A person opens `/sessions` on a phone, 390 px wide, wanting to know
where their tokens went this month and what is being worked right now.

## Expected behaviour

The page shows, with no search box and no filter chips anywhere:

1. What needs them, as today.
2. A usage panel: the headline total for the chosen range, marked as the
   full API rate; a bar for each quota window with its reset countdown;
   and a per-day series. Toggles switch cost to tokens, and 7 to 30 to
   90 days.
3. `NgheNhanTrading` as a workspace heading, with its cost and cache
   share, holding `market-data-pipeline`, `nghenhan-mt5` and
   `trading-data-api`, each with its own cost and share.
4. `market-data-pipeline` shows `symbol-onboarding` under **working**,
   because a live session carries its `goal:` label, with the crew's own
   row beneath it, and `session-aware-sink-health` folded under **done**.
5. `kitterm` appears without a workspace heading, because its parent
   holds no other project, and shows its ten goals folded under
   **done**, with `$699.93` beside it.
6. The foreman's row takes a typed line and sends it.

## Expected persistent effects

The daily rollup gains no day it did not have; reading the page writes
nothing but a dismissal.

## What passes

The 390 px and 1200 px screenshots of the fixture, and the vitest cases
each capability names in `plan.md`. A range whose days are all before
the oldest surviving transcript still draws, from the rollup.
