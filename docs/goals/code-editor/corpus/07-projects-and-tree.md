# The human's word: projects and a livelier tree

2026-10-24, after v0.47.1:

> For editor, I want to quick access to the registor projects. Also the
> directory tree looks bored. Let's give me solution to enhance it

The foreman proposed, and the human chose:

- Projects: **both, in two rounds** — the header switcher and the
  `/edit` home page first, then a ⌘P quick open with a file index.
- Tree: **all four** — indent guides, file-type tags, dimmed ignored
  files, compact folders with keys.
- Tag colour: **coloured by language**, a `design/foundation.md`
  exception, as the diff colours were.

The rules, named so the human can amend them:

1. **The home page.** `/edit` with no path lists the projects, one line
   each: the name, the root under `~`, the branch and the changed count
   when the project is a checkout. Registered projects come first, then
   the ones a live pane discovered (`GET /api/projects`). A line opens
   `/edit?path=<root>`. It replaces `No file named. …`.
2. **The switcher.** The project name in the `/edit` header opens the
   same list; a choice opens that project's root in `/edit`, after a
   question when the buffer is edited.
3. **Indent guides.** Hairline guides show the folder a row sits in, the
   fleet tree's joins (`pass`, `tee`, `end`) in `--ui-border`.
4. **File-type tags.** A short tag in one fixed column before each name
   (`ts`, `md`, `sw`, `js`, `{}` for JSON, `sh`, …), coloured by a
   `--code-*` token per language. A folder and an unknown type carry no
   tag. This is the second place a colour paints text that is not a
   state, after the diff lines; the round that draws it proposes the
   wording for `design/foundation.md`.
5. **Dimmed ignored files.** An entry that `.gitignore` excludes
   (`.build`, `node_modules`, `dist`) shows in the faint grey, as VS
   Code does. The daemon says which paths are ignored; it still lists
   them.
6. **Compact folders.** A chain of folders that each hold one folder and
   nothing else shows as one row, `Web/terminal/src`.
7. **Keys.** In the tree, `↑` `↓` move the selection, `←` folds or goes
   to the parent, `→` opens a folder, `Enter` opens a file.
8. **⌘P quick open.** A palette finds a file of the open project by
   fuzzy name from an index the daemon builds (`git ls-files` for a
   checkout), and lists the projects to jump to. It is the last round.
9. Every rule of `design/foundation.md` holds but the one exception of
   rule 4: monospace, hairlines, no icon font, no radius above 2 px, no
   transition, 44 px tap targets below 768 px.
