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

3 capabilities, one branch `goal/markdown-preview`, one pull request.

| # | Capability | Proof |
|---|---|---|
| 1 | **The renderer.** A pure `Web/terminal/src/markdown.ts`: Markdown text to a block tree (ATX and setext headings, paragraphs, block quotes, ordered and bullet lists with nesting, task items, fenced and indented code, thematic breaks, GFM tables with alignment) with inlines (emphasis, strong, strikethrough, code spans, links, images, autolinks, hard breaks, backslash escapes, entities), then a DOM builder that uses `textContent` and sets only the attributes it names; the link and image rules of `goal.md`; fenced code through `highlight.ts`. | Vitests: one per block and inline form against a hand-written tree, the security cases of condition 3, and a 1 MB file parsed under a time bound. |
| 2 | **The design.** A browser draft of the rendered view in the overlay and on `/md` from a real file of this repository, both themes and both widths, for the human's choice; then the approved draft in `design/markdown.pen`, edited headless, with its exports. | The human approves; the foreman writes `corpus/01-approved-design.md` with the commit. |
| 3 | **The views.** The overlay renders a `.md` file with the toggle and a full-width link; the `/md` page (a new Vite input the daemon serves at `/md`) takes `?path=` through `GET /api/files/content` and `?project=&path=` through the knowledge route; the fleet view's goal and record links open `/md`; the cut notice; the toggle kept per viewer. | Vitests on the page and the overlay; the foundation's proofs; screenshots against a scratch daemon. |

Capability 1 does not depend on the design and runs while the human
chooses the draft. Capability 3 depends on 1 and 2.
