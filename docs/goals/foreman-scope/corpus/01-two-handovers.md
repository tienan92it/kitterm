# Two handovers, 2026-09-25

Measured by the kitterm foreman from its own session and the archive of
the foreman before it.

## The first handover went wrong

The human runs two foremen on one daemon: one in
`/Users/antran/Workspace/kitterm` for kitterm, one in
`/Users/antran/Workspace/NgheNhanTrading` for backend, backend-goals,
infrastructure, market-data-pipeline and nghenhan-mt5. The skill says the
opposite: "One foreman runs per daemon and serves every project", and "When
`list_sessions label="crew:foreman"` shows a live session that is not
yours, stop and tell the human."

On 2026-09-25 the human told a new pane "you are the kitterm foreman,
archive the old one". The pane found a live `crew:foreman` session in the
NgheNhanTrading workspace, read the NgheNhanTrading projects' goal files,
and archived that session (`D7D30375`), which ended its `claude`. The human
was angry; the conversation survived only because it had been resumed in
another pane. That foreman then archived itself on the human's word. The
scope rule now lives in one foreman's memory file, not in the skill.

## The second handover was done by hand

The next kitterm foreman had to rebuild the picture itself, in this order:

1. `list_sessions` for live sessions, and `list_archives` for the
   predecessor. The archive listing was 113,268 characters in one line, too
   large for the tool's output, and had to be parsed with a script.
2. The predecessor's archive row (`0031638F`): its `note` and its
   `agentTranscript` path, then the last messages of that transcript, to
   learn what it was doing when it stopped and what the human had said.
3. Every goal's `STATE.md`, for status, round and next action.
4. `gh pr list`, `gh run list` and `git branch -a`, for open work and CI.
5. `git worktree list`, for a stale worktree the predecessor left.

None of this is written down, so the next foreman will do it again, and a
foreman that skips step 2 does not learn what the human told its
predecessor.

## The human's words, 2026-09-30

"Foreman should have ability to manage the projects in its scope."

"When I start a new foreman, it should sync up with the works of the other
foreman."
