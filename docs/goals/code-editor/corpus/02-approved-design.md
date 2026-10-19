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

## The approved frames

2026-10-18, the human approved the six frames of `design/editor.pen`
at commit 01ac6ff (`rounds/002.md`) and their exports in
`design/exports/editor-*.png` at that commit: `Editor 1200`,
`Editor 1200 git`, `Editor 390`, `Editor 390 files`, `Editor 390 git`
and `Editor components` with its 16 rules. The same answers approved:

6. **The words.** The buffer states `● edited`, `◐ saving`, `✓ saved`,
   `– read only`; the bar `? Changed on disk since you opened it.
   [ reload ] [ compare ] [ keep mine ]` and, on a refused save,
   `! Not saved: changed on disk since you opened it.` with the same
   three actions; the read-only reasons, the empty tree, the missing
   project, a failed git command and the in-flight states as
   `rounds/002.md` lists them.
7. **Stage control**: a `[ ]`/`[x]` toggle per changed file stages the
   whole file; hunk staging stays in lazygit.
8. **Compare** shows the buffer-against-disk diff in the editor area,
   unified, as the git view does, until `[ reload ]` or `[ keep mine ]`.
9. **The foundation** gains, on the human's word: the diff line colours,
   `md-code` as the editor's size, and the phone key bar as the `keys-`
   component (`design/foundation.md`).
