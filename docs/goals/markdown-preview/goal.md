# Goal: Markdown files render in the pane preview and on a page of their own

## Objective

A `.md` file opened from a pane's output, or from a goal or round-record
link on `/sessions`, shows as formatted text: headings, paragraphs,
emphasis, lists, task lists, block quotes, fenced code coloured by
`highlight.ts`, tables, links and images. One toggle switches to the
coloured source with line numbers. The overlay opens the file full width
at `/md`. kitterm parses Markdown with its own pure renderer and no new
dependency. The request and the choices are `corpus/00-request.md`.

## Exclusions

- No new npm dependency, no `innerHTML`, no raw HTML pass-through: a
  file's `<script>`, `<iframe>` or `onload=` prints as text.
- No editing: the page shows a file; it does not write one.
- No Mermaid, no math, no footnotes, no front-matter rendering (front
  matter shows as a code block).
- No remote image fetch: an image is shown only when it is a relative
  path the daemon's preview route serves as an image; any other image is
  its alt text and its address as text.

## Completion condition

All 7 hold on a build from `main`:

1. The overlay and the `/md` page match the design at the commit
   `corpus/01-approved-design.md` names, at 1200 px and 390 px, in the
   dark and the light theme.
2. A vitest suite pins the renderer on CommonMark and GFM cases for
   every block and inline form the objective names, with hand-written
   expected trees.
3. A security vitest pins that raw HTML, `javascript:`, `data:` and
   `vbscript:` links, and event-handler attributes in a file all reach
   the DOM as text, and that no rendered node carries an attribute the
   renderer did not set.
4. A link to another relative `.md` file opens that file in the same
   view; an `http`, `https` or `mailto` link opens in a new tab with
   `rel="noopener"`; any other scheme is text.
5. The toggle shows the coloured source with line numbers, and the
   choice is kept per viewer.
6. `/md?path=<file>` (full grade) and `/md?project=<id>&path=<knowledge
   path>` (watch grade, through the knowledge route) both render, and
   the fleet view's goal and record links open the second form.
7. A file over the preview's byte cap renders the part that came and
   says that it is cut.

The floor (Linux build, `swift test`, the web checks) is green at every
step.
