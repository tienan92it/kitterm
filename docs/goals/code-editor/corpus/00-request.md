# The human's request

2026-10-18, in the foreman's pane:

> can it have a small built-in code editor with kitterm? Let's do a deep
> research and report me. The rule is still lightweight tool. The
> built-in IDE should be very lightweight and minimalist. The core
> features of IDE:
> - Project directory tree.
> - Popular programming language supported.
> - Quick git control.

The research is `corpus/01-research.md` (five research tracks: editor
engines, file tree and git, write security, the terminal alternative,
and the fit with kitterm's code; the bundle sizes were measured with
esbuild on 2026-10-18). Its decision record proposes four phases:
terminal tools first, then a CodeMirror 6 page at `/edit` with a jailed
save route, then git reads, then git writes behind `--agent-control`.

The human's word after the report, 2026-10-18:

> start phase 0 and phase 1

So this goal covers, in its first budget:

- **Phase 0, decide**: the ADR 0005 proposal (`docs/adr/`, Propose
  tier: the human accepts it), and the design of the `/edit` page — a
  browser draft for the human's choice, then the frames in
  `design/editor.pen` at 390 px and 1200 px.
- **Phase 1, the terminal stack**: micro or `$EDITOR` and lazygit in
  kitterm's own panes, with the four client additions of the research:
  copy that reaches the viewer's device (OSC 52, write only), touch
  scrolling in an alternate-screen program, "open in editor" on a path
  link (with `:line:col`), and a layout preset of an editor, lazygit and
  a shell.

Phases 2 to 4 (the `/edit` page, git reads, git writes) are a later
budget, after the human accepts the ADR and the frames.
