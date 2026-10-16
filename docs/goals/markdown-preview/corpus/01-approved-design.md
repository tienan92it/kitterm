# The approved design

2026-10-16, the human chose draft A of two browser drafts the foreman
drew in the pane overlay with the live terminal page's own CSS and a
section of this repository's `README.md` (`draft-a-b.png` beside this
file: A on the left, B on the right; B set everything in the monospace
font with a faint `##` before each heading and was not chosen).

```
README.md                [x] rendered [ ] source  open full width  ✕

The MCP bridge                     (17 px, semibold)
────────────────────────────────────────
[kitterm mcp] is a stdio MCP server that hands an agent...
 • Session: [list_sessions], [get_session], ...
┌─ code block, sunken ─┐
│ { "mcpServers": ... } │
└─────────────────────┘
```

The rules the draft fixes:

1. **Prose in `--font-ui`**, 14 px at a line height of 1.6, the text at
   most 72 characters wide.
2. **Headings at sizes**: h1 22 px and h2 17 px, each with a hairline
   in `--ui-border` under it; h3 15 px; all semibold.
3. **Inline code** in `--font-mono` in a small box on
   `--ui-surface-2` with a hairline; **code blocks** on
   `--ui-bg-sunken` with a hairline, coloured by `highlight.ts`'s
   token classes.
4. **Tables** with hairline cells and a header row on `--ui-surface-2`;
   **task items** as disabled checkboxes; **block quotes** with a 2 px
   rule in `--ui-border` and the text in `--ui-text-muted`; **links** in
   `--ui-accent`, underlined.
5. **The overlay header** keeps the file name and its size, then
   `[x] rendered [ ] source`, then `open full width` as a link, then
   the close button.

## The approved frames

2026-10-16, the human approved the six frames of `design/markdown.pen`
at commit d4c0b2f (`rounds/002.md`) and their exports in
`design/exports/markdown-*.png` at that commit: `Markdown overlay 1200`
and `390`, `Markdown page 1200` and `390`, `Markdown page 1200 light`,
and `Markdown components` with its 13 rules. The same answers approved:

6. **The words.** The cut header `<size> · the first <cap> shown` and
   the last line `Showing the first <cap> of <size>.`; the error
   `Cannot read <path>: <reason>.` (`the daemon answered 404`); the
   empty file `<name> is empty.`
7. **The `/md` header** is one bar: the path in mono and the size at
   the left, the toggle at the right, no close; the column is at most
   72 characters and centred, full width on a phone.
8. **The foundation**, on the human's word: round 3 adds to
   `design/foundation.md` a `ui` font token (`--font-ui`) for prose
   pages; `surface-2` and `sunken` as named tokens with a light value
   each, and `tokens.css` gives `--ui-bg-sunken` a light value, so a
   code well is light on a light theme; and the `md-*` sizes (14, 22,
   17, 15, 12.5; the 72-character measure) as the one exception to the
   three-size type scale, for prose only.
9. **The link** is underlined on the page, by the foundation's rule,
   though a saved `.pen` file drops the underline.
