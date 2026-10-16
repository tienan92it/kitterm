# The human's request

2026-10-16, in the foreman's pane:

> Let's implement Markdown preview built-in feature

The foreman's facts, the same day:

- A pane's output already links a path; a click opens the file overlay
  (`Web/terminal/src/file-preview.ts`). The daemon decides what is safe
  (`FilePreview`, `X-Kitterm-Kind`: image, pdf, text, binary; SVG is
  refused) and `GET /api/files/content` serves the bytes, full grade
  only. A `.md` file shows today as coloured source with line numbers
  (`highlight.ts`, the `md` grammar). Every span is built with
  `textContent`: a file's bytes never become markup.
- The fleet view's goal and round-record links open
  `GET /api/projects/<id>/knowledge/<path>`, served as `text/plain`, at
  watch grade.
- The pages are Vite multi-page inputs (`index.html`, `sessions.html`);
  the daemon serves `/sessions` from `sessions.html`.

The human's choices, 2026-10-16:

1. **Where: the pane overlay and a full page.** The overlay renders a
   `.md` file and offers to open it full width at a page of its own; the
   fleet view's goal and round-record links open that page too, in place
   of the raw `text/plain`.
2. **Default: rendered, with a toggle to source.** One `[x] rendered
   [ ] source` toggle; the source view is today's coloured source with
   line numbers.
3. **Renderer: our own, no dependency.** A pure TypeScript parser for
   CommonMark with GFM tables, task lists and fenced code (coloured by
   `highlight.ts`), building the DOM with `textContent` only, so raw HTML
   in a file shows as text.
