# STATE: agent-dashboard

- Status: active
- Round: 2 of 3 in this budget (second budget)
- Rounds total: 5
- Last floor: green (2026-09-18, round 5 after: Linux green, swift test 803, vitest 1301 in 45 files, bench p95 2.98 ms)
- Updated: 2026-09-18, round 5 closed

## Queue

1. `the-page-says-what-the-spend-bought` (capability 7)
2. `every-line-is-one-line` (capability 5, last: it shapes the lines the
   others create, and it owes 47 px at 390)

## Failures

None.

## Proposals waiting on the human

- **`corpus/design-foundation.md`, "The model": the 4 KiB sentence is
  measured false.** The last assistant line sits within 4 KiB in 3 of 40
  transcripts, within 256 KiB in 40 of 40. The code uses 256 KiB. The
  corpus is Frozen, so the human changes the sentence. See
  `rounds/005.md`.
- **`AGENTS.md`'s fleet entry still describes the reply line** capability
  1 removed. One sentence; capability 5 rewrites that paragraph anyway.
- **The anatomy's "actions" cell** lists "`[new]`, the `…` menu, or
  nothing", and an approval's `[Deny]`/`[Allow]` now live there. Name
  them in the foundation or move them.

- `site/index.html` sets `--accent: #3fb950`. The dashboard's palette is
  the Coolors set the human chose, so the site and the page no longer
  share a colour. Not blocking; the human decides whether the site
  follows.
- `dashboard.pen` is open in Pencil and unsaved. The MCP server has no
  save tool, so the human saves it to
  `docs/goals/agent-dashboard/corpus/dashboard.pen`. The four frame
  exports and the written contract are committed either way.

## Done

- `every-agent-says-its-model` (capability 6), round 5, PR #129. See
  `rounds/005.md`. A session's row carries its model, and
  `GET /api/usage/daily` answers a per-model split whose parts sum to
  the total to 1e-6 on every day. One 256 KiB `pread` off the event
  loop, cached by size and mtime, so an unchanged file costs one `stat`.
  A pre-change rollup loads unchanged. The crew measured the
  foundation's 4 KiB claim and found it false; the sentence is a
  proposal for the human.
- `the-band-replaces-the-strip` (capability 4), round 4, PR #128. See
  `rounds/004.md`. One fixed row of four counts replaces the strip; its
  items became marks on the lines they belong to. The band's height held
  at 89 px and 29 px across 0, 4, 20 and 2000 items and 60-character
  nouns — principle 2 measured, not asserted. Three strip-shape assertion
  groups were named and replaced with one that pins the promise.
- `a-task-is-the-fourth-level` (capability 3), round 3, PR #127. See
  `rounds/003.md`. `KnowledgeSummary` parses `## Queue`, `## Done` and
  `## Failures` into a task list the knowledge route serves, and the page
  paints one line per task with the crew's row nested under the task it
  runs. Failed beats pending beats done; a live `task:` label overrides
  all three. No heading yields `nil`, not `[]`, which is eleven of
  thirteen goals.
- `the-foundation-in-the-stylesheet` (capability 2), round 2, PR #126.
  See `rounds/002.md`. Rule C expressed as a page-scoped `:root` in
  `sessions.css`, which loads only on `/sessions`, so `tokens.css` is
  byte-identical and the pane at `/` is untouched. `light-dark()`
  carries the light theme with no JavaScript. The ratchet **shrank**, 61
  entries to 55, because `.notice` stopped painting `--ui-danger` as
  text. The three hues clear 3:1 on all 17 bundled themes, lowest 3.49.
- `no-input-on-the-page` (capability 1), round 1, PR #125. See
  `rounds/001.md`. No element on the page accepts typed text. The crew
  took out the form and everything that existed only to serve it. 390 px
  page 1340 to 1174, 1200 px 1099 to 933, fields 3 to 0. One chartered
  deletion: `sessions-reply.test.ts` and its 16 assertions.

## Direction

2026-09-17: the human said the session UI is still ugly and hard to use,
and asked for a dashboard that presents and monitors workspaces and
agents. They named the scope: workspaces, projects, goals, tasks. They
named the design language: minimalism, clean, an agentic feel. They
asked for a design foundation before any implementation. And they asked
for the "Answer Workspace" input to go.

The foreman asked one question, because two readings led to different
work: whether the input goes everywhere or only where it is unusable.
The human answered **everywhere**. The page presents and monitors; it
accepts no typed work. That answer is principle 1 of the foundation and
exclusion 1 of `goal.md`.

The foreman researched before planning. Four measurements shaped the
plan, and `corpus/inventory.md` holds them all: the page is 2202 px tall
at 390 px with 587 elements and 100 class names; the task level has a
source in every `STATE.md` that nothing reads; the colour tokens are
sound and everything above them is ad hoc; and no block has a fixed
height, so a reader never learns where to look.

The Pencil design tool was not reachable — its MCP server reported
`transport not connected to app` on both calls — so the foundation is a
written contract plus a visual specimen page rather than a `.pen` file.

## Direction, continued

2026-09-17: the human asked for the LLM model on a session or agent's
info. The foreman measured the two sources before planning it. A live
session's model is the last `"model"` field in its `agentTranscript`,
which the session payload already carries: a 4 KiB tail is enough, and
40 reads cost 10 ms in total. The spend by model is the `modelUsage` map
on each transcript's final `cost-state` line, which `TranscriptBill`
already reads and `UsageRollup` throws away. Over the last 30 days seven
ids appear, led by `claude-fable-5-1` at $1,283.48 and
`claude-opus-5[1m]` at $404.43. It is capability 6.

2026-09-17: the human asked to measure and show valuemaxxing. The
foreman read it as: how much delivered work each dollar buys, and which
lever moves that number. `corpus/valuemaxxing.md` holds the research;
if the reading is wrong, that file is the thing to correct.

Seven findings, all measured against real transcripts, real round
records and the repository's own merge history. Yield is measurable:
kitterm's last 30 days cost $976.74 and bought 83 merged PRs at $11.77
each, 58,853 lines at 1.7 cents, and 24 releases at $40.70. Delegation
is the lever: a crew in a worktree costs $42 an API hour against $61 in
a root session, 31% cheaper. Most spend has no unit attached: 14 of 51
round records carry a `Cost:` line and 14% of account spend runs in a
crew worktree. And one finding removes something the page draws today:
the cache share is 95–99% on every session over $5 but three, so it is a
constant, and it leaves every heading for an exception line.

Three things the research refuses to claim: a quality rate, because
every one of the 51 rounds records `done`; a rework rate, because two
commits in 30 days is noise; and a money value for the work, because
nothing here knows the human's hourly rate and the page takes no input.

It is capability 7.

## Next action

Round 6, `the-page-says-what-the-spend-bought`, from `plan.md` row 7. It
reads the per-model split round 5 just shipped and takes the cache share
off every heading.

Capability 5 then owes 47 px: round 5 left the 390 px page at 1247,
against a completion condition of 1200.

The design is settled and frozen: `corpus/design-foundation.md` holds
the contract, `corpus/palette.md` holds five palette rounds and the
measurements behind each, and the six frames in Pencil draw it with real
numbers.
