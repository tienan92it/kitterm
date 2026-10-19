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

## Second budget (2026-10-19, `corpus/03-all-phases.md`)

| # | Capability | Proof |
|---|---|---|
| 3 | **The save route** (phase 2a): `ETag` on `GET /api/files/content`; `PUT /api/files/content` with the jail, the atomic save, `If-Match`, the editor header, the Origin check, the audit log; on its own queue. | Swift tests for every refusal of condition 7 and a save that keeps the mode; `KittermBench` on a scratch daemon. |
| 4 | **The `/edit` page** (phase 2b): a Vite input on CodeMirror 6 with lazy languages, the tree on `GET /api/files`, save with `If-Match`, the changed-on-disk bar, compare in the editor area, the read-only states, the 390 px tabs and key bar, `edit` links from the preview card and `/md`. | Vitests on the pure parts; Playwright against a scratch daemon at 1200 and 390 px (a save, a 412 from an outside edit, a read-only file); the bundle sizes. |
| 5 | **Git reads** (phase 3): status (`--porcelain=v2 -z --branch`) and the diff of one file, with `--no-optional-locks` and `-c core.fsmonitor=`, per-repository serial queue; the git tab, badges in the tree, the diff view. | Swift parser tests; a test that a poll does not hold `index.lock`; Playwright of the git tab. |
| 6 | **Git writes** (phase 4): stage, unstage, commit (`-F -`), push, branch switch and create, allowlisted argv, behind full grade and `--agent-control`; hook output; 409 on a held lock. | Swift tests on a scratch repository with a hook and a lock; Playwright of a commit and a push to a scratch remote. |
