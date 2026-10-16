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

Still open for the Pen round: the `/md` page's own header and width,
the 390 px layout, the light theme, the cut notice of `goal.md`
condition 7, and the empty and error states.

The frames in `design/markdown.pen` that carry this design, and their
commit, are added here once the human approves them.
