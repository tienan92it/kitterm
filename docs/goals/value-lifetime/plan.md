# Plan

The initial floor and the expected capability order for the goal in
`goal.md`. A human owns this file. A foreman proposes a change to it in a
round record; it does not edit it.

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Linux build | the `facts.md` docker pipe with `swift build --build-tests`; the PR's `linux-build` check proves it | `Build complete` |
| Swift tests | `swift test`, once by the crew; the PR's `test` check proves it again | exit 0 |
| Web | `Web/terminal`: `tsc --noEmit`, `vite build --outDir <scratch>`, `vitest run` | exit 0 |

A round that changes the page ships the proofs of `design/foundation.md`.
Each round adds at least one deterministic check. A check that exists is
frozen (see `LOOP.md`).

## Capability order

4 capabilities, one branch `goal/value-lifetime`, one pull request.

| # | Capability | Proof |
|---|---|---|
| 1 | **The design.** TOTALS and UNIT COSTS under VALUE in `Dashboard 1200` and `Dashboard 390` of `design/dashboard.pen`, and their parts in `Components`: the dash patterns, the end labels in shorthand, the axes, a tooltip, the note on missing early spend, the empty state; real data from `corpus/02-direction.md`. Edited headless with the pen CLI. Changed on the human's word, 2026-10-09. | The human approves; the foreman writes `corpus/03-approved-design.md` with the commit. |
| 2 | **The counts per day.** `GET /api/yield/daily?from&to` (or a `days` field on `/api/yield`): merged pull requests, merged lines and releases per day, per project and summed, by the rules `RepositoryYield` already counts by, on its queue, cached. | New Swift tests against a scratch repository with dated merges and tags. |
| 3 | **The series.** A pure `value-lifetime.ts`: from the rollup's days and the yield's days, the four cumulative totals and the four unit costs, by the rule of `corpus/02-direction.md`, and the shorthand formatter. | A vitest on a fixture with a hand-computed answer, the shorthand cases, and the empty case. |
| 4 | **The charts.** VALUE draws TOTALS and UNIT COSTS as the approved frames show: SVG, the dashes, labels, tooltips, the note, one sentence each for a screen reader, the phone layout, hidden for a watch page. | The foundation's proofs; a check against the live daemon on three days of the human's table. |

Capability 2 does not depend on the design and runs while the human
reviews round 1. Capability 3 depends on 2; capability 4 on 1 and 3.
