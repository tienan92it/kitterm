# The human's word: all phases of the editor

2026-10-19, after v0.44.0 shipped phases 0 and 1:

> Run until complete all editor phases

This opens the second budget of the goal: phases 2 to 4 of
`docs/adr/0005-editor-terminal-first-then-codemirror.md` (accepted
2026-10-18), on the frames the human approved at 01ac6ff
(`corpus/02-approved-design.md`).

What the word charters, named so the human can amend it:

1. **The dependency.** `Web/terminal/package.json` and
   `Web/terminal/pnpm-lock.yaml` (Propose and Frozen tiers) change for
   the CodeMirror 6 packages the `/edit` page needs (`@codemirror/*`,
   `@lezer/*`) and nothing else; only the `/edit` input imports them,
   so `main-*.js` keeps its size. ADR 0005 accepted this dependency.
2. **The write route.** `PUT /api/files/content` is the first HTTP
   route that writes outside `~/.kitterm/`, with the rules of ADR 0005
   and `corpus/01-research.md`: full grade, jailed to the project root
   by an `O_NOFOLLOW` descriptor walk, an atomic save, a SHA-256
   `If-Match` (412 on a mismatch, 428 when missing), a required editor
   header and an exact Origin, a 0600 audit log, existing regular files
   only.
3. **The git routes.** Reads (status, diff) at full grade; writes
   (stage, unstage, commit, push, branch switch and create) at full
   grade plus `--agent-control`, because a commit runs the repository's
   hooks.
4. **No stop between rounds** for a direction check: the foreman runs
   the rounds in order and reports at each round's end; it stops only
   for a decision that is the human's.
