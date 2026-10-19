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

2 capabilities in this budget, one branch `goal/code-editor`, one pull
request.

| # | Capability | Proof |
|---|---|---|
| 1 | **The terminal stack** (phase 1): OSC 52 write-only on xterm.js's OSC parser; touch drag to wheel reports in the alternate screen; "open in editor" on a path link with `:line:col`; the editor + lazygit + shell layout preset; install hints for a missing program. The foreman writes the ADR 0005 proposal and the browser draft of `/edit` while this runs. | Vitests per addition; a screenshot of the layout; a phone or touch-emulated scroll check; the OSC 52 read refusal. |
| 2 | **The design** (phase 0): the human's chosen draft of `/edit` (tree, editor, git panel) as frames in `design/editor.pen` at 390 px and 1200 px, edited headless, with exports. | The human approves; the foreman writes `corpus/02-approved-design.md` with the commit. |

Phases 2 to 4 of the research are a later budget, after the direction
check and the ADR.
