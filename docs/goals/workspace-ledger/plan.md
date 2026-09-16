# Plan

The initial floor and the expected capability order for the goal in
`goal.md`. A human owns this file. A foreman proposes a change to it in a
round record; it does not edit it.

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift tests | `swift test` | exit 0, 729 tests at the start |
| Web | `Web/terminal: tsc --noEmit && vite build && vitest run` | exit 0, 1222 at the start |
| Bench | `swift run KittermBench interactive-echo` | p95 under 50 ms |
| Linux build | the `facts.md` pipe into `swift:6.1` | `Build complete`, 0 errors |

Read `corpus/data-sources.md` before the first round. It settles what
exists and what does not, with the paths.

## What the research settled

**The quota is live-only.** No file on disk carries it. 777 transcripts
hold no rate-limit field. But Claude Code hands a `rate_limits` object to
the **statusline script's stdin** on every render:
`five_hour`, `seven_day` and `spend_limit`, each with `used_percentage`
and an epoch-seconds `resets_at`. The human's `~/.claude/statusline.sh`
already receives it and drops it. So the daemon can have it only if
something running inside a session gives it, and the statusline is that
something. **The screenshot's per-model "Weekly · Fable" row has no local
source at all**; `goal.md` excludes it.

**The cost series is derivable, and the exact method needs no price
table.** Each transcript's last line carries an exact `totalCostUSD` and
per-model `costUSD`; every assistant line carries an ISO `timestamp` and
its `usage`. So a session's exact cost can be apportioned across the days
it ran, in proportion to each day's share of that session's tokens.
A session that runs inside one day, which is nearly all of them, is then
exact; one that spans midnight is apportioned, and the page says so.
Summing per-turn tokens against a published price table would also work
and is rejected: `goal.md` excludes a price table.

**History runs out at 30 days.** `cleanupPeriodDays` defaults to 30 and
the oldest surviving transcript is exactly 30 days old, so a 90-day view
built on transcripts alone is a truncated line. The daemon must keep its
own daily rollup for history to accumulate past that, which is why
capability 4 exists before capability 5 needs it.

**Today's totals, for scale.** 777 transcripts over 57 project
directories, 118 with a final bill, `$1,131.93` summed. `kitterm` is
`$699.93` of it.

**A workspace is derivable and is not modelled.** Nothing in the daemon
knows the word. `~/.kitterm/projects.json` holds a root per project and
`GET /api/projects` returns four, three registered and one discovered.
The parent directory of a root is the workspace: `NgheNhanTrading` holds
four, and `kitterm` sits directly under `Workspace`, which is the
degenerate case a design must handle rather than pretend away.

**The page today** renders header, strip, notice, restart line, cards,
filters, push line. The filters are `chipGroups`, the `Choice` state, and
the model's `filter()`; `group()` is independent of them and stays.

## Capability order

Five capabilities. Each ships as one PR. Each names the check that proves
it.

| # | Capability | Proof |
|---|---|---|
| 1 | **Three levels, no filters.** The page groups workspace, then project, then goal state. A workspace is the parent directory of a project root; one that holds a single project shows no header of its own. Goals sort into working when a live session carries that `goal:` label, pending when the goal is `active` with no crew or is `waiting` or `stopped`, and done folded. The search box, the four chip groups, the `Choice` state and the model's `filter()` all go. | A vitest over the grouping model: two workspaces, a single-project workspace, a project with goals in each of the three states, and an unregistered checkout. A 390 px screenshot of the live page. No `filter` symbol remains in `sessions-model.ts`. |
| 2 | **Answer a foreman or a crew from the page.** A row with a live agent takes a line of text and posts it to `POST /api/sessions/<id>/input?enter=1`. The control is absent for a watch-grade client, and says why when the daemon runs without `--agent-control` rather than failing silently. | A route test for the two refusals; a vitest over the control's states; and a live check that a line typed on the page reaches a running `claude` pane, driven against a scratch daemon, never 3418. |
| 3 | **Capture the quota.** `POST /api/usage/limits` takes the `rate_limits` object a statusline render is given; the daemon keeps the newest and serves it at `GET /api/usage/limits` with the age of the reading. `kitterm skills install`, or whatever installs the statusline, teaches the script to post it. The page shows one bar per window with its reset countdown, and says plainly when no reading has ever arrived. | Route tests for post, get, an absent reading and a stale one; a vitest over the bar model including the never-seen case; and one real reading captured from a live session and shown. |
| 4 | **A daily rollup that outlives retention.** The daemon reads the transcripts it can still see, apportions each session's exact `totalCostUSD` across the days it ran by that day's token share, and keeps a daily file of cost and tokens by kind per project. It refreshes on start and on a timer, and never loses a day it has already recorded, so history grows past Claude Code's 30 days. `GET /api/usage/daily?from=&to=` serves it. | Unit tests over the apportionment: a one-day session, a session across midnight, and a session with no bill. A test that a rollup file already holding a day older than any surviving transcript keeps that day. A route test for the range. |
| 5 | **The numbers on the page.** Each workspace, project and goal heading carries its cost and its cache share. One panel shows the headline total with "if billed at full API rate", the per-day series as a sparkline, and toggles for cost or tokens over 7, 30 or 90 days. | Corpus request `01-where-did-it-go`; a vitest over the panel model for each toggle and for an empty range; screenshots at 390 px and 1200 px. |

Capability 1 is independent and goes first, because every later capability
hangs its numbers on the headings it creates. Capability 2 is independent
of 3, 4 and 5. Capability 4 must land before 5, which reads its route.
Capability 3 is independent of all of them. The human sees the images
after 1 and after 5 before either merges, because both change the page's
shape.
