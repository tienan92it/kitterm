# Research: what the page is today

Measured on the live daemon on 2026-09-17, kitterm v0.30.0, `main` at
`2eee3cf`. The two before-images beside this file show the same page at
390 px and at 1200 px.

## The answer first

The page is a **stack of six unrelated lists**, not a dashboard. It
answers "what exists" and does not answer "what is happening". Four
measurements say so, and each one names a capability in `plan.md`.

| Measure | Today | Why it matters |
|---|---|---|
| Page height at 390 px | 2202 px | A reader scrolls five screens to see one fleet. |
| DOM elements | 587 | For seven sessions and thirteen goals. |
| Distinct CSS class names | 100 | One page, 100 one-off names, no system. |
| Levels rendered | 3 | Workspace, project, goal. The **task** is invisible. |

## Structure: the six blocks

The page paints one fixed order. Heights are the live measurement at
390 px.

| Block | Height | What it holds |
|---|---|---|
| `header` | 24 px | Title, session count, "Open a shell". |
| `strip` | 619 px | Everything that needs a person: approvals, sessions waiting for input, failed sessions, live goals' proposals. |
| `usage` | 241 px | The 30-day total, the day bars, the apportionment note. |
| `quota` | 124 px | One bar per rate-limit window, the reset countdown, the age. |
| `cards` | 1033 px | The three-level tree, the session rows, the archived folds. |
| `push` | 24 px | The notification toggle. |

**The order is wrong for monitoring.** 984 px of alarm and accounting sit
above the first piece of work. A person opening the page wants to see
the fleet, then drill into what is wrong. Today they read the alarms
first and must scroll past the accounting to reach the fleet.

**The blocks do not share an idiom.** The strip is a list of stacked
paragraphs. The usage panel is a chart with radio rows. The quota is
text-cell bars. The cards are a nested tree with folds. Nothing tells
the reader that the strip's "foreman" and the card's "foreman" are the
same pane.

## The missing level

`goal.md` for this goal names four levels: workspace, project, goal,
task. The page renders three. A goal line today reads:

```
the dashboard groups the work and says what it costs
waiting  round 3 of 3  $75.11 · 98% cached
None until the human answers. The second budg…
```

Round and next action, and the next action truncated. The **task** —
the unit a crew actually runs — never appears.

**A task has a source and it is already written.** Every goal's
`STATE.md` carries three sections that name tasks, and `LOOP.md` defines
the `task:` label as the queue item slug.

| Task state | Source | Shape |
|---|---|---|
| working | a live session's `task:<slug>` label | the crew's own row |
| pending | `## Queue`, a numbered list | ``1. `slug` (capability N)`` |
| done | `## Done`, a bullet list | ``- `slug` (capability N), round N, PR #NNN.`` |
| failed | `## Failures` | free text, usually empty |

Sampled across eleven `kitterm` goals and two `market-data-pipeline`
goals: every one uses this shape, and `KnowledgeSummary` parses none of
it. The summary carries `slug`, `goal`, `status`, `round`, `budget`,
`lastFloor`, `nextAction`, `proposals`, `lastRound`, `lastRecord`,
`lastDecision`, `costUSD`, `inTokens`, `cacheReadTokens`. No task field.

## The agent is not modelled either

The user asked for a dashboard that monitors **workspaces and agents**.
The page has no idea of an agent. It has sessions, and a session may or
may not hold an agent. What exists per session today:

- `agentStatus`: `working`, `needs-input`, `needs-approval`, `completed`,
  from the hook reports.
- `agentAt`: when the last report arrived.
- `foregroundProgram`: `claude`, `zsh`, or another name.
- the `crew:`, `goal:`, `round:`, `task:` labels the foreman sets.
- the archive bill: cost, tokens, cache share, wall time.

That is enough to say, for any moment: **which agents are working, which
are waiting on a person, what each one is working on, and what it has
cost**. The page says none of it in one place. It scatters the same
agent across the strip, a card row and a goal line.

## The visual system

**Tokens exist and are good.** `tokens.css` derives every colour from the
terminal's own theme: `--ui-bg` from `--term-bg`, `--ui-text` from
`--term-fg`, `--ui-accent` from `--term-accent`, and the surfaces and
borders from `color-mix` against `--ui-lift`. The contrast ratchet in
`theme-contrast.test.ts` measures every pair against every bundled
theme. **Keep this. Build the foundation on it.**

**Everything above the tokens is ad hoc.**

- **Type scale: four sizes, no system.** 35 rules at 12 px, 6 at 13 px,
  3 at 16 px, 1 at 18 px. The 16 px is the reply field alone, which this
  goal removes; the 18 px is the `h1`. So the real page is two sizes,
  12 and 13, and the difference between them carries no meaning.
- **Spacing: no scale.** Paddings and margins are written per rule in
  raw pixels. There is no `--space-1`.
- **100 class names.** Sampled: `strip-top`, `strip-what`, `strip-who`,
  `strip-waited`, `strip-open`, `strip-quiet`, `strip-item`,
  `strip-list`. Eight names for one list item. The same shape elsewhere
  is `head`, `name`, `state`, `since`, `actions`, `more`, `menu`.
- **No density control.** Every row is 44 px tall because the tap target
  says so, on a 1200 px desktop as much as on a phone.

## What the reference images show

`00-quota-bars-reference.png` and `00-token-usage-reference.png`, which
the human gave with the previous goal and which stay beside this file as
inputs, not as the design. Two things carry over and one
does not.

- **Carry over: a bar is a measure against a whole.** The quota bars
  already do this. The design foundation makes it one component rather
  than a special case.
- **Carry over: a number and its unit sit on one line, large, with the
  qualifier small beside it.** `$2,316.83 if billed at full API rate`
  already does this.
- **Does not carry over: the per-model row.** No local source, and
  `goal.md` of the previous goal excluded it. It stays excluded.

## What a dashboard adds that a list does not

Three properties, and the page has none of them.

1. **A fixed frame.** A dashboard's blocks stay where they are, so a
   reader learns where to look. Today every block's height moves with
   its content and the tree pushes everything down.
2. **State at a glance before detail.** A dashboard opens with a small
   number of large facts, then lets the reader drill. Today the first
   large fact is 619 px of alarm text.
3. **Change over time.** A dashboard shows a direction, not only a
   value. The page has one series, the day bars, and nothing else says
   whether a thing is getting better or worse.

## Facts a later round must not rediscover

- `GET /api/projects` returns id, name, root, knowledge dir, registered.
  It does **not** return goals. `GET /api/projects/<id>/knowledge`
  returns `{ok, project, goals}` with one `KnowledgeSummary` per goal.
- `GET /api/projects/<id>` alone is **not a route**; it is 404.
- The knowledge summary is built by `KnowledgeSummary.parse`, which
  reads `STATE.md` bullets by key and sections by heading. Adding a task
  list means one more section parse, and the same file already proves
  the technique.
- A goal's cost comes from the `- Cost:` line of each round record, not
  from the rollup, because the rollup keys on a directory.
- The page's whole colour system already passes the contrast ratchet on
  every bundled theme. A new colour must pass it or be listed.
