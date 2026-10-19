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
