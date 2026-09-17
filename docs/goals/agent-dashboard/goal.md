# Goal: /sessions is a dashboard for workspaces and agents

## Objective

A person opens `/sessions` and reads the state of their whole fleet in
one screen: how many agents are working, how many wait for them, what
the work is costing, and how much quota is left. Below that, the same
fleet in four levels — workspace, project, goal, task — one line each,
so the reader can follow a workspace down to the task an agent is
running right now, and read which model that agent is running on. The
page presents and monitors. It accepts no typed work.

The design language is the one in `corpus/design-foundation.md`:
minimal, monospace, hairline, three type sizes, one space scale, eight
components, colour on the state mark alone.

## Exclusions

- **No text input anywhere on the page.** The reply field, the `[send]`
  control and the held-reason text all go. The input route stays for the
  MCP bridge and the pane; the page stops using it.
- **No new colour.** The four semantic tokens already exist and already
  pass the contrast ratchet. A round that wants a fifth stops and says
  so.
- **No new data source.** Every number comes from a route that exists,
  from a `STATE.md` section that every goal already writes, or from a
  transcript field Claude Code already writes. The task level and the
  model both parse what is there; neither asks a human to write more.
- **No per-model quota row.** `workspace-ledger` excluded it because the
  rate limits are not per model and no local source carries one. That
  exclusion stands. Cost per model is a different fact with a real
  source, and it is in.
- **No change to the terminal pane.** `/` is not this goal's surface.
- **No loss of an accessibility rule an earlier round paid for.** The
  list is in `design-foundation.md` under "What the page keeps".
- **No density control, no theme picker, no settings.** Density follows
  the width. The theme follows the terminal.

## Completion condition

All eight hold on a build from `main`:

1. The top band is one fixed-height row of four counts — agents working,
   items needing a person, spend over the chosen range, quota used — and
   its height does not change with the fleet.
2. The tree renders four levels: workspace, project, goal, **task**. A
   task's state is working, pending, done or failed, read from the
   goal's `STATE.md` and from a live session's `task:` label.
3. Every line in the tree is one line at 390 px: a mark, a name, its
   facts, its time. Nothing wraps.
4. No element on the page accepts typed text. A vitest asserts that the
   rendered page contains no `input`, `textarea` or `contenteditable`.
5. `sessions.css` uses the space scale and the three type sizes from
   `design-foundation.md`, and a vitest reads the file and pins both.
6. The page at 390 px is under 1200 px tall with the live tree loaded,
   and the first screen holds the band, the meters, and the first
   workspace.
7. A session running an agent shows its model as a fact on its line, and
   the meters carry one row per model with its spend and its cache
   share. A model with no reading prints nothing rather than a guess.
8. The floor is green and `main` is green after the merge.

The floor (`swift test`, the web suite with the contrast ratchet,
`KittermBench interactive-echo` under 50 ms p95, and the Linux build) is
green at every step.
