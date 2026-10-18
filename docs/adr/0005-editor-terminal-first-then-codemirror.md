# ADR 0005: The editor ships as terminal tools first, then a CodeMirror 6 page

## Status

Proposed (2026-10-18). The research is
`docs/goals/code-editor/corpus/01-research.md`.

## Context

The owner wants a small built-in editor with three features: a project
tree, popular-language support and quick git control. kitterm must stay
a light tool. The terminal page already costs 167 KB gzip of
JavaScript; Monaco's core alone costs 703 KB gzip and its own README
says it does not support mobile browsers. The daemon adds no blocking
I/O to the event loop and passes `swift test` and `KittermBench` with
no regression (`AGENTS.md`). Every HTTP write today stays under
`~/.kitterm/`; an editor save would be the first write into the user's
projects. Claude Code edits the same files in the panes, so a save can
race an agent. The phone is a target, and xterm.js touch support is not
a priority for its maintainer (xterm.js #5377).

## Decision

We deliver the editor in four phases.

1. We run micro (or `$EDITOR`) and lazygit in kitterm panes, and we add
   OSC 52 copy (write only), touch scrolling in the alternate screen,
   "open in editor" on a path link, and a layout preset. No daemon
   route changes.
2. We build `/edit` on CodeMirror 6 with lazily loaded languages, a
   tree on `GET /api/files`, and `PUT /api/files/content`: full grade,
   jailed to the project root by an `O_NOFOLLOW` descriptor walk, saved
   atomically by a temporary file and a rename, and checked by a
   SHA-256 `If-Match` (412 on a mismatch, 428 when it is missing).
3. We add read-only git routes: status and the diff of one file.
4. We add stage, commit, push and branch routes behind full grade plus
   `--agent-control`, because a commit runs the repository's hooks.

We run the git CLI on the daemon through `PullRequestStatus.run`; we
use no git library.

## Consequences

- Phase 1 delivers all three features with 0 web bytes and no new
  write route, before any new security surface.
- The `/edit` page costs about 120 KB gzip (an esbuild estimate) and
  leaves `main-*.js` unchanged, because only `/edit` imports
  CodeMirror.
- kitterm takes a CodeMirror dependency with one primary maintainer,
  against the zero-dependency choice of `highlight.ts`.
- The save route widens the write boundary from `~/.kitterm/` to every
  project root; it needs an audit log and tests for symlinks, hard
  links, FIFOs and APFS name forms. The atomic save breaks hard links,
  so the route refuses a hard-linked file.
- The editor has no code intelligence; a language server is a separate
  decision.
- A user without `--agent-control` commits in lazygit, not on `/edit`.
- Long edits on a phone and screen-reader access stay weak in phase 1.
- This closes Monaco, Ace, isomorphic-git, an editor as a split-pane
  leaf, an unjailed write route, and a save with no precondition.
