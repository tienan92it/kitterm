# The human's word: a wider column, tables that do not break

2026-10-17, in the foreman's pane, after v0.42.0 shipped:

> Content width looks small. Table text is broken lines

The foreman's measurement the same day, on the live `/md` page with
`markdown-preview/plan.md` at a 1440 px window: the prose column is
635 px (the 72-character measure of `corpus/01-approved-design.md`
rules 1 and 7), so more than half the window is empty; every table is
held to that column, so a header (`Pass condition`) and a first cell
(`Linux build`) wrap, and a code span in a cell
(`corpus/01-approved-design.md`) breaks at its hyphens.

What this changes, on the human's word (the foreman's defaults, named
here so the human can change them):

1. **The column** on `/md` and in the overlay card is at most 980 px
   (GitHub's content width) in place of 72 characters; it stays
   centred on `/md` and full width on a phone. The overlay card grows
   to hold it.
2. **A table** is not held to the prose line: a header cell does not
   wrap, a code span in a cell does not break, and a table wider than
   the column scrolls inside itself, never the page.
3. Rule 1's 72-character measure and rule 7's "at most 72 characters"
   are replaced by rule 1 above; every other rule of
   `corpus/01-approved-design.md` holds.
