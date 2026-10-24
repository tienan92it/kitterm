# STATE: code-editor

- Status: active
- Round: 2 of 5 in this budget (sixth budget, `corpus/07-projects-and-tree.md`)
- Rounds total: 11
- Last floor: green (2026-10-24, round 11 after: PR CI on 3ba7558)
- Updated: 2026-10-24, the human approved the frames and the tag colour (`corpus/09-approved-frames.md`)

## Queue

1. `project-access`: the `/edit` home page and the header switcher
   (rules 1, 2), PR #203.
2. `tree-polish`: guides, tags, dimmed ignored files, compact folders,
   keys (rules 3 to 7).
3. `quick-open-palette`: ⌘P with the file index (rule 8).

## Failures

None.

## Proposals waiting on the human

None. 2026-10-24: the human approved the frames of rounds 10 and 11,
their words, and the tag-colour exception (`corpus/09-approved-frames.md`).

## Done

- `tree-design-revision`, round 11, PR #203. See `rounds/011.md`.
  Vertical guides only, one space after the triangle.
- `editor-design-2`, round 10, PR #203. See `rounds/010.md`. Seven
  frames in `design/editor.pen`.
- `editor-dotfiles`, round 9, PR #202. See `rounds/009.md`. The tree
  lists dotfiles and hides VS Code's `files.exclude` names.
- `editor-markdown-preview`, round 8, PR #201. See `rounds/008.md`. The
  `[x] source [ ] preview` switch for a Markdown file in `/edit`.
- `quick-open`, round 7, PR #199. See `rounds/007.md`. `/edit` on a
  folder, `kitterm edit`, and ⌘⇧E in a pane.
- `git-write`, round 6, PR #198. See `rounds/006.md`. Stage, commit,
  push and branch from `/edit`, behind `--agent-control`.
- `git-read`, round 5, PR #198. See `rounds/005.md`. Git status and
  diff, the git tab, tree badges.
- `edit-page`, round 4, PR #198. See `rounds/004.md`. The `/edit` page
  on CodeMirror 6.
- `save-route`, round 3, PR #198. See `rounds/003.md`. The jailed atomic
  `PUT /api/files/content` and the `ETag` on the read.
- `editor-design`, round 2, PR #197. See `rounds/002.md`. Six frames in
  `design/editor.pen`.
- `terminal-stack`, round 1, PR #197. See `rounds/001.md`. OSC 52, touch
  scroll, open in editor, the editor layout, and the DECRQM freeze fixed.

## Next action

Round 12: `project-access`.
