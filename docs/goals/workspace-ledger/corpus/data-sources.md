# What exists for the dashboard and the usage panels, 2026-09-16

Read-only research done before the goal was planned. Every path was
opened; nothing here is assumed.

## The quota, and the one row that cannot be built

**Nothing on disk carries it.** Across 777 transcripts under
`~/.claude/projects/*/*.jsonl` there is no `rate_limit`, `rateLimit`,
`resetsAt`, `five_hour`, `weekly`, `usage_limit` or `utilization` as a
JSON key. `~/.claude.json` holds only UI copy templates, for example
`spentLine = "Weekly reset used · available again {date}"`, a string with
a placeholder and no value. `~/.claude/stats-cache.json` has daily
message, session and tool-call counts back to January and no cost and no
quota. `~/.claude/usage-data/report.html` has behaviour statistics and no
figures. `~/.kitterm/` has nothing.

**It exists live, at the statusline.** Claude Code hands the statusline
script a JSON object on stdin at every render, and since v2.1.251 it
carries:

```json
"rate_limits": {
  "five_hour":   { "used_percentage": 23.5, "resets_at": 1738425600 },
  "seven_day":   { "used_percentage": 41.2, "resets_at": 1738857600 },
  "spend_limit": { "used_percentage": 62.8, "resets_at": 1740787200 }
}
```

`resets_at` is epoch seconds. Each window appears only for a Pro or Max
subscriber, only after the first API response of a session, and each is
dropped once its own reset passes. The installed Claude Code is 2.1.266
to 2.1.273, so the field is supported.

`~/.claude/statusline.sh` already receives this object on every render.
It reads `.model.display_name`, `.context_window.remaining_percentage`
and `.cost.total_cost_usd`, and ignores `.rate_limits`. Nothing writes it
anywhere, so it is lost each render.

**The per-model row cannot be built.** The schema has `five_hour`,
`seven_day` and `spend_limit` and no per-model field. The reference
screenshot's "Weekly · Fable" has no local source; it exists only in the
`/usage` command's own output or on the account page.

## The cost series

**Per turn**, every assistant line carries an ISO `timestamp` such as
`2026-09-04T09:30:31.436Z`, its `message.model`, and `message.usage` with
`input_tokens`, `output_tokens`, `cache_creation_input_tokens` and
`cache_read_input_tokens`.

**Per session**, the last line is `cost-state`, with an exact
`totalCostUSD`, an epoch-milliseconds `startTime`, and `modelUsage`
carrying a per-model `costUSD` and its token counts.

**Only 118 of 777 transcripts have that line.** The rest are sessions
still open, or short-lived job and probe transcripts that never wrote a
final summary.

**Two ways to a per-day series.** Summing per-turn tokens against a
published price table is exact and needs a price table, which `goal.md`
excludes. Attributing a whole session's cost to the day of its
`startTime` needs nothing and is wrong for any session that spans
midnight. The third way, which this goal takes, is to apportion a
session's exact `totalCostUSD` across the days its turns fall on, by each
day's share of that session's tokens: exact for a session inside one day,
which is nearly all of them, and an apportionment for one that spans
midnight, which the page says.

**History runs out at 30 days.** `~/.claude/settings.json` sets no
retention override, so `cleanupPeriodDays` defaults to 30, and the oldest
surviving transcript is exactly 30 days old: `partner-connect-hub`, 17
August, against today's 16 September. A 90-day view over transcripts
alone is a truncated line. Only a rollup the daemon keeps itself will
accumulate past that.

## What the dollars mean

`totalCostUSD` is priced at the full pay-as-you-go API rate, the same
number on any plan. On a Max plan the subscriber pays a flat fee and is
not billed per token. So the reference screenshot's "$4,129 · if billed
at full API rate" beside "Cost to you: $0" is exactly this number beside
the plan's reality.

## Today's totals

777 transcripts over 57 project directories, 118 with a final bill,
**$1,131.93** summed. The ten dearest directories:

| Decoded path | Transcripts | Billed | Cost |
|---|---|---|---|
| `Workspace/kitterm` | 58 | 56 | $699.93 |
| `/Users/antran` (home and job sessions) | 123 | 2 | $89.47 |
| `NgheNhanTrading/nghenhan-monorepo`, a worktree | 1 | 1 | $63.06 |
| `Workspace/diagram-generation` | 1 | 1 | $34.84 |
| `kitterm/.claude/worktrees/open-the-elevation` | 2 | 2 | $24.34 |
| `kitterm/.claude/worktrees/the-ledger` | 1 | 1 | $15.84 |
| `kitterm/.claude/worktrees/the-toggle` | 1 | 1 | $14.75 |
| `kitterm/.claude/worktrees/send-on-transition` | 1 | 1 | $13.77 |
| `Workspace/NgheNhanTrading` | 7 | 5 | $13.43 |
| `NgheNhanTrading/market-data-pipeline` | 5 | 5 | $13.35 |

A directory name is the cwd with every `/` replaced by `-`, so a path
component holding a dash cannot be told from a separator by pattern
alone. A worktree gets its own directory, which is why a goal's rounds
are spread across several.

## The project model, and the workspace that is not in it

The word `workspace` appears nowhere in `Sources/` or `Web/`. A project
is a registered root from `~/.kitterm/projects.json` with `id`, `name`,
`root` and `knowledge`; a resolved project is that, or a `.git` checkout
found by walking up from the cwd, or a `project:<id>` label. Round 2 of
`foreman-harness` set the rule: the nearest ancestor that is a checkout
or a registered root wins.

`GET /api/projects` returns four today: `kitterm`,
`market-data-pipeline` and `nghenhan-mt5` registered, and
`trading-data-api` discovered because a session sits in it. No entry
carries a workspace.

The parent of a root is the workspace: `NgheNhanTrading` holds four, and
`kitterm` sits directly under `Workspace` beside twenty unrelated
folders, which is the degenerate case a design must handle.

## The goal model

`KnowledgeSummary.parse` reads `STATE.md`, `goal.md` and the newest
round record; `GET /api/projects/<id>/knowledge` serves `slug`, `goal`,
`status`, `round`, `budget`, `lastFloor`, `nextAction` capped at 512
bytes, `proposals`, `lastRound`, `lastRecord` and `lastDecision`.

`Status` is `active`, `waiting`, `stopped` or `done`. `active` means
runnable, not running: a goal can be active with no round open. So
"working" is better read from a live session carrying that goal's
`goal:` label than from the status word.

A session is tied to a goal by its labels: `crew` holds the goal slug,
or `foreman`, or `helper`; `goal`, `round` and `task` carry the rest.

## What the page can already do to a session

Rename, archive, kill, spawn, open the pane, and answer an approval,
which is the one place it already answers a live agent.

`POST /api/sessions/<id>/input` exists and the page does not use it. It
writes bytes as if typed, takes `?enter=1`, and is gated twice: full
grade only, and the daemon must run with `--agent-control` or every call
answers `agent control disabled`. That route is the whole of what
"interactive" can mean; there is no higher-level reply API.

## The page today

In order: `header`, the `announce` live region, `strip`, `noticeLine`,
`restartLine`, `cards`, `filters`, `pushLine`. The filters are
`chipGroups`, the `Choice` state in `sessionStorage`, `currentFilter`,
and the model's `filter()` with its `Filter` and `Kind` types. `group()`
is independent of all of it and stays.
