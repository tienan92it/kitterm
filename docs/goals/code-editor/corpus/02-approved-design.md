# The approved design of `/edit`

2026-10-18, the human chose draft B of two browser drafts the foreman
drew with the live terminal page's own CSS, this repository's
`Web/terminal/src/md.ts`, and the git state of this goal
(`draft-b.png` beside this file; `draft-a.png` showed three columns,
tree | editor | git, and was not chosen).

```
kitterm / Web/terminal/src/md.ts  ● edited  TypeScript·LF·UTF-8   [ save ⌘S ]  open in terminal
┌───────────────────┬───────────────────────────
│[x] files [ ] git 3│20 import "./tokens.css";
│▼ Web/terminal/src │21 import "./styles.css";
│  file-preview.ts M│...
│  md.ts         M  │
│  osc52.ts      A  │
```

The rules the draft fixes:

1. **Two columns**: a sidebar of 280 px at 1200 and the editor. The
   sidebar switches between the tree and the git panel with
   `[x] files [ ] git <N>`, where N counts the changed files.
2. **The header bar**: the project and the path, `● edited` in the
   warning colour while the buffer differs from disk, the language,
   the line ending and the encoding, then `[ save ⌘S ]` and
   `open in terminal` at the right.
3. **The tree**: one level per expand, a faint triangle, git badges
   `M` (warning), `A` (success), `D` (danger) at the right of a row, the
   open file's row on `--ui-surface-2`.
4. **The git panel**: `BRANCH` with ahead and behind, `CHANGES <N>`
   with a badge, the name and `+a −d` per file, `COMMIT` with a message
   box and `[ commit ]` `[ push ]` in the accent.
5. **The editor**: CodeMirror 6 on `--ui-bg-sunken`, the gutter of
   line numbers in the faint text colour, the `tok-*` colours of the
   source view; everything in the monospace font, hairlines, no radius
   above 2 px, no transition (`design/foundation.md`).

Still open for the Pen round: the 390 px layout (the research's
`files | edit | git` tabs), the states (a file changed on disk, a
save refused with 412, a read-only file, the empty tree, a git command
that failed), and the stage control per file.

The frames in `design/editor.pen` that carry this design, and their
commit, are added here once the human approves them.
