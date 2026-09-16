# Goal: the dashboard groups the work and says what it costs

## Objective

A person opens `/sessions` and sees their work in the shape they hold it
in: a workspace, the repositories inside it, and each repository's goals
sorted into what is being worked, what is pending, and what is done.
There are no filters, because the grouping is the navigation. A foreman
or a crew can be answered from the page without opening its pane. Beside
each workspace, each project and each goal sits what it has cost and how
much of its input came from cache, so a reader can see where the tokens
went. One panel shows the quota that is left in the current window and
the next reset, and one shows cost and tokens per day over the last
week, month or quarter.

## Exclusions

- No price table. A cost comes from what Claude Code already wrote, or
  it is not shown.
- No per-model quota row. The screenshot's "Weekly · Fable" has no local
  source; the daemon can only know what a running session's statusline
  is given.
- No new way to talk to an agent. Answering from the page uses the input
  route that exists, with the grade and `--agent-control` gates it
  already has.
- No change to what a round record carries, and no rewrite of the
  ledger's own table; `kitterm goal cost` keeps its shape.
- No workspace configuration file. A workspace is derived from where a
  project's root sits, until that proves wrong.

## Completion condition

All six hold on a build from `main`:

1. `/sessions` groups sessions and goals by workspace, then project,
   then goal state: working when a crew is live on it, pending when it is
   not, done folded. No search box and no filter chips exist on the page.
2. A foreman or crew row takes a typed answer from the page, which
   arrives in that session as if typed, and says plainly when the daemon
   runs without `--agent-control` or the token is watch grade.
3. `GET /api/usage/limits` serves the newest quota reading the daemon has
   been given, with each window's used fraction and reset time, and says
   how old the reading is. The page shows a bar per window and the
   countdown, and says when it has never been given one.
4. The daemon keeps a daily cost and token rollup that outlives Claude
   Code's own 30-day transcript retention, and `GET /api/usage/daily`
   serves it for a range.
5. The page shows cost and cache share on every workspace, project and
   goal heading, and a panel with the headline total, the per-day series,
   and toggles for cost or tokens over 7, 30 or 90 days.
6. The floor is green and `main` is green after the merge.

The floor (`swift test`, the web suite, `KittermBench interactive-echo`
under 50 ms p95, and the Linux build) is green at every step.
