# Goal: kitterm offers a minimal editor with a project tree and quick git control

## Objective

A kitterm user edits code with a project tree, popular-language
support and quick git control without leaving kitterm, and kitterm
stays a light tool. The first budget delivers the terminal stack
(phase 1 of `corpus/01-research.md`): an editor and lazygit in
kitterm's own panes, with the four client additions that make them
work from a browser and a phone; and the decision (phase 0): the ADR
0005 proposal and the approved design of the `/edit` page. The request
is `corpus/00-request.md`.

## Exclusions

- No new npm dependency in this budget (`Web/terminal/package.json` is
  Propose tier): OSC 52 is handled with xterm.js's own OSC parser.
- No route that writes outside `~/.kitterm/` in this budget; the save
  route is phase 2, after the ADR is accepted.
- kitterm does not install micro, helix or lazygit; it names the
  install command when a program is missing.
- No change to the daemon's output path.

## Completion condition

All 6 hold on a build from `main`:

1. A program that writes OSC 52 (`printf '\e]52;c;%s\a' "$(printf hi |
   base64)"`, micro's and lazygit's copy) puts the text on the viewing
   device's clipboard; a read request (`?`) is refused and answered
   with nothing.
2. A finger drag scrolls an alternate-screen program that has mouse
   reporting on (micro, lazygit, less), on a touch device; a drag on
   the normal screen scrolls the scrollback as today.
3. A path link in the output offers "open in editor"; it opens a split
   running `$EDITOR` (else `micro`, else `vi`) at that path, at
   `:line` when the link carries it; a `path:line:col` link resolves to
   the file.
4. One action lays out a pane as editor, lazygit and shell in the
   pane's cwd; a missing program prints its install command in its
   pane instead of failing silently.
5. `docs/adr/0005-…` exists with status `Proposed`, and the human has
   accepted or amended it.
6. The `/edit` frames at 390 px and 1200 px are in `design/editor.pen`
   at the commit `corpus/02-approved-design.md` names.

The floor (Linux build, `swift test`, the web checks) is green at every
step.

## Second budget (2026-10-19, `corpus/03-all-phases.md`)

The objective grows to phases 2 to 4: the `/edit` page on CodeMirror 6
with a jailed save route, git reads, and git writes. The first
budget's exclusion of a new dependency and of a write outside
`~/.kitterm/` is lifted by `corpus/03-all-phases.md` rules 1 and 2;
the others hold.

Completion condition of this budget, all 7 on a build from `main`:

7. `PUT /api/files/content` saves an existing regular file in a
   project atomically, refuses a symlink anywhere in the path, a
   dangling symlink, a hard-linked file, a FIFO, a path under `.git`
   (any case), and a path outside every project, answers 412 on a
   stale `If-Match` and 428 without one, 403 without the editor header
   or with another Origin or at watch grade, and writes one audit line
   per save; `GET /api/files/content` sends the `ETag`.
8. `/edit?path=<file>` matches the frames at 01ac6ff at 1200 and
   390 px: the tree, the editor with lazily loaded languages, save,
   `● edited`, the changed-on-disk bar with reload, compare and keep
   mine, the read-only states; the preview card and `/md` offer `edit`.
9. The `/edit` page's own bundle is measured and `main-*.js` is
   unchanged in size within 1 %.
10. The git tab shows the branch with ahead and behind, the changed
    files with badges in the list and the tree, and the unified diff of
    a file, read with `--no-optional-locks` off the event loop; a poll
    never makes an agent's `git commit` fail on `index.lock`.
11. Stage and unstage a file, commit with a message, push the current
    branch, and switch or create a branch from the page, behind full
    grade and `--agent-control`; hook output and a failed command's
    first line show; a held `index.lock` answers 409.
12. Every route above is full grade only; a watch token reaches none.
13. `swift test`, the web checks and `KittermBench` show no regression.
