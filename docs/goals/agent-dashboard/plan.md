# Plan

The floor and the capability order for the goal in `goal.md`. A human
owns this file. A foreman proposes a change to it in a round record; it
does not edit it.

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Linux build | the `facts.md` docker pipe, run first when a round touches `Sources/` | `Build complete`, 0 errors |
| Swift tests | `swift test` | exit 0, 780 at the start |
| Web | `Web/terminal`: `tsc --noEmit`, `vite build`, `vitest run` | exit 0, 1286 in 41 files at the start |
| Bench | `swift run KittermBench interactive-echo` | p95 under 50 ms |

Read `corpus/inventory.md` and `corpus/design-foundation.md` before the
first round. The inventory settles what the page is; the foundation
settles what it becomes, and a round does not invent a token or a class
prefix outside it.

Every round ships the four proofs `design-foundation.md` names: a
vitest, a CSS assertion, screenshots at 390 px and 1200 px against the
**real** `docs/goals/` tree, and the page height at both widths before
and after.

## What the research established

`corpus/inventory.md` holds the measurements. Four of them set the
capability order.

**The page is a stack of six lists, 2202 px tall at 390 px, with 587
elements and 100 distinct class names.** 984 px of alarm and accounting
sit above the first piece of work.

**The task level has a source and nothing reads it.** Every goal's
`STATE.md` writes `## Queue`, `## Done` and `## Failures` in a shape
that has not varied across thirteen goals, and `LOOP.md` defines the
`task:` label as the queue item slug. `KnowledgeSummary` parses none of
it.

**The token layer is sound and the layer above it is not.** `tokens.css`
derives every colour from the terminal's theme and the ratchet measures
every pair. Above that there is no space scale, four type sizes with no
meaning, and 100 one-off class names.

**The page has no fixed frame.** Every block's height moves with its
content, so a reader never learns where to look.

## Capability order

Five capabilities. Each ships as one PR. Each names the check that
proves it.

| # | Capability | Proof |
|---|---|---|
| 1 | **The page stops taking input.** Every text field, the `[send]` control and the held-reason text go, from the row, the strip item and the approval line. `Open the pane` is the only way to act on an agent. `POST /api/sessions/<id>/input` is untouched: the MCP bridge and the pane keep it. | A vitest asserts the rendered page contains no `input`, `textarea` or `contenteditable` for a fixture holding a working agent, a waiting agent and a pending approval. The route tests for the input endpoint stay green and unchanged. The 390 px screenshot shows no field. |
| 2 | **The foundation lands in the stylesheet.** The five space tokens and the three type tokens from `design-foundation.md` are defined and used; no rule writes a raw pixel for space; no rule sets a font size outside the three. Density follows the width: 44 px below 768 px, 28 px at and above it. | `sessions-css.test.ts` reads the file with `node:fs` and pins: the eight tokens exist, no `margin`/`padding`/`gap` uses a bare pixel, no `font-size` outside the three tokens, and the `--line-h` media query. The ratchet is unchanged and green. Screenshots at both widths on `github-dark` and `solarized-dark`. |
| 3 | **A task is the fourth level.** `KnowledgeSummary` parses `## Queue`, `## Done` and `## Failures` into a task list with a slug and a state, and the knowledge route serves it. The page renders a task under its goal, one line each, with the working task carrying its crew's row. | Swift tests over the parser: a numbered queue, a done bullet with a round and a PR, an empty section, a `Failures` section with prose, and a slug that appears in two sections. A vitest over the task model including the live `task:` label join. A screenshot against the real tree showing a goal with tasks in three states. |
| 4 | **The band replaces the strip.** One fixed-height row of four counts: agents working, items needing a person, spend over the range, quota used. The "need you" count links to the first marked line. The strip's items become a mark on the line they belong to, and the strip is gone. | A vitest over the band model: the four counts, the empty fleet, and the case where nothing needs a person. A vitest asserting no session appears twice on the page. The band's height is the same in a fixture with 0, 4 and 20 items needing a person. Screenshots at both widths. |
| 5 | **Every line is one line.** The tree's line component carries mark, indent, name, facts, time and actions, and its facts drop from the right in a fixed order as the line narrows. Nothing wraps at 390 px. | A vitest over the line model for each level and each drop step. A measurement in the live check: every line's `scrollHeight` equals one `--line-h` at 390 px. The page at 390 px is under 1200 px tall with the live tree loaded. |

Capability 1 is independent and goes first, because it removes code the
later capabilities would otherwise have to carry. Capability 2 goes
second, because every later capability writes CSS and should write it
against the scale. Capability 3 is independent of 4. Capability 5 needs
3 and 4, because it shapes the lines they create. The human sees the
images after 2 and after 5 before either merges, because both change how
the page looks.
