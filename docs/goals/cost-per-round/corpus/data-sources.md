# What exists to measure cost and return, as of 2026-09-15

Read-only research done before the goal was planned. Every path was
opened and every field was seen; nothing here is assumed.

## Claude Code's own record

**Where.** `~/.claude/projects/<cwd with slashes as dashes>/<session>.jsonl`.
`/Users/antran/Workspace/kitterm` becomes
`~/.claude/projects/-Users-antran-Workspace-kitterm/`. A git worktree gets
its own directory keyed by its own path. The file name is the Claude Code
session id, and every line inside carries it as `sessionId`. This id is
not the kitterm session id; nothing links them today.

**Per turn.** Every `"type":"assistant"` line carries `message.usage`:

```json
{"type":"assistant","sessionId":"e89e7ec8-…","model":"claude-fable-5-1",
 "usage":{"input_tokens":2,"cache_creation_input_tokens":14947,
 "cache_read_input_tokens":31200,"output_tokens":211,
 "output_tokens_details":{"thinking_tokens":22}}}
```

No dollars at this level.

**Per session, already totalled.** The last line of every transcript is
`"type":"cost-state"`, written when the session ends:

```json
{"type":"cost-state","sessionId":"…","totalCostUSD":2.63612375,
 "totalAPIDuration":244888,"totalAPIDurationWithoutRetries":244867,
 "totalToolDuration":908,"totalLinesAdded":0,"totalLinesRemoved":0,
 "totalDuration":347686,"startTime":1788922267579,
 "modelUsage":{"claude-fable-5-1":{"inputTokens":450,"outputTokens":17680,
   "thinkingTokens":9245,"cacheReadInputTokens":1022235,
   "cacheCreationInputTokens":74427,"costUSD":2.63259875}},
 "hasUnknownModelCost":false}
```

Claude Code computes the dollars itself. The line always exists but can
be zeroed with `modelUsage: {}` when a session recorded no billable turn.
Seen at line 182 of 182 in one transcript and line 6113 of 6113 in
another.

`user` and `assistant` lines also carry `cwd`, `gitBranch`, `version` and
an ISO `timestamp`.

## What the daemon already sees and drops

`Sources/KittermDaemon/AgentHooks.swift` installs four hooks:
`PermissionRequest`, `PreToolUse`, `Notification`, `Stop`. No
`SessionStart`, `SessionEnd` or `PostToolUse`.

`HTTPAPIHandler.swift`, `serveHook` and `handleHookEvent`: the payload is
parsed into a dictionary and only `tool_name`, `tool_input` and `message`
are read. Every hook payload also carries `session_id` and
`transcript_path` per the hooks reference, and both are discarded.

`grep -n "token\|cost\|usage" Sources/KittermDaemon/EventLog.swift`
returns nothing. `Sources/KittermDaemon/` has no notion of a token or a
dollar.

`SessionCommands.swift` times shell commands; `SessionRecorder.swift`
times recordings. Neither times a `claude` turn.

`~/.kitterm/history/` is kitterm's own output history keyed by kitterm
session id. `~/.kitterm/recordings/` is asciinema frames. Neither holds
cost.

## What a round record carries

From `docs/goals/LOOP.md` "Round record" and three real records:
`Sessions:` and `Archives:` ids, `Started:` and `Ended:` with zone,
`Base:` and `Result:` shas or a PR number, a Floor line with test counts
before and after and "N new", Effects with the file list and visible
proof, `Gap: class:`, `Decision:`, `Reflection:`.

Missing: tokens, dollars, and the crew's own wall-clock as distinct from
the round's. No record names a transcript or a Claude Code session id, so
there is no join key today.

## What "return" can be read from the repository today

| Measure | Read from |
|---|---|
| Merged PRs | `git log --format=%s` on `main`; 26 unique `(#N)` since 2026-09-09 |
| Rounds to close a goal | `docs/goals/<slug>/STATE.md`, `Rounds total:`; 4, 7, 5, 5, 8, 4, 2 across the seven goals |
| Tests added per round | each record's Floor line, "N tests, 0 failures, M new" |
| Review findings fixed | records whose gap or decision names a blocking finding; six files mention one |
| Gap-class distribution | every record's `class:` line |

None of these is a token or a dollar. That axis is the gap this goal
closes.

## Tools

`ccusage` is not installed. Claude Code's statusline JSON, fed to a
`statusLine` script, carries `cost.total_cost_usd`,
`cost.total_duration_ms`, `cost.total_api_duration_ms`,
`cost.total_lines_added` and `_removed`, and `context_window.*`; the
same shape as the transcript's `cost-state`. The dollar figure a pane
shows is rendered by the `claude` process; kitterm does not parse or
store it. Hook payloads carry no token or cost field.

Sources: the Claude Code statusline and hooks references, and the files
named above.
