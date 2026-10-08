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
| 1 | **The design.** The LIFETIME chart under VALUE in `Dashboard 1200` and `Dashboard 390` of `design/dashboard.pen`, and its parts in `Components`: the four dash patterns, the line labels, the axis, a tooltip, the one-sentence empty state. The human opens `design/dashboard.pen` in Pen before the round and saves it after. | The human approves; the foreman writes `corpus/01-approved-design.md` with the commit. |
| 2 | **The counts per day.** `GET /api/yield/daily?from&to` (or a `days` field on `/api/yield`): merged pull requests, merged lines and releases per day, per project and summed, by the rules `RepositoryYield` already counts by, on its queue, cached. | New Swift tests against a scratch repository with dated merges and tags. |
| 3 | **The series.** A pure `value-lifetime.ts`: from the rollup's days and the yield's days, the four cumulative unit costs and their index, by the rule of `corpus/00-request.md`. | A vitest on a fixture with a hand-computed answer, and the base-day and empty cases. |
| 4 | **The chart.** VALUE draws LIFETIME as the approved frames show: SVG, the four dashes, labels, tooltips, one sentence for a screen reader, the phone layout, hidden for a watch page. | The foundation's proofs; a check against the live daemon on three days. |

Capability 2 does not depend on the design and runs while the human
reviews round 1. Capability 3 depends on 2; capability 4 on 1 and 3.
