# STATE: agent-dashboard

- Status: waiting
- Round: 2 of 3 in this budget (third budget)
- Rounds total: 9
- Last floor: green (2026-09-18, round 9 after: swift test 823, vitest 1384 in 50 files)
- Updated: 2026-09-18, round 9 closed

## Queue

Empty.

## Failures

None.

## Proposals waiting on the human

- **`corpus/design-foundation.md`, Hierarchy**: "below 768 px a goal's
  done tasks fold behind one line, the way a project's done goals do."
  Round 7's first answer. See `rounds/007.md`.
- **`corpus/design-foundation.md`, The panels**: `VALUE` folds at 390 px
  with `WHERE` and `MODELS`. The current sentence says it does not; that
  was round 6's foreman call and round 7 priced it at 187 px.
- **`corpus/valuemaxxing.md` has four numbers the parser disagrees with.**
  84 merged PRs not 83, 59,251 lines not 58,853 (a one-day range), 2
  corrections not 3, and **7 sessions over $5 under 95% cached worth
  $64.92, not 3 worth $33.54**. The conclusion holds — $64.92 of $2,458
  is still not a lever — but on the measured number. The corpus is
  Frozen. See `rounds/006.md`.
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

- `others-not-a-count` (round 9), PR #133. See `rounds/009.md`. The
  summed model row reads `Others`; the names it covers stay in its
  `title`. Four assertions updated, all round 8's own, two of them
  stronger than before. Nothing moved: the summary line, the title and
  the panel's height are unchanged on both builds.
- `models-top-three` (capability 8), round 8, PR #132. See
  `rounds/008.md`. The `MODELS` panel shows the top three by cost and
  sums the rest into one row, `4 more models`, which is a row with a bar
  and a count rather than a footnote. Seven rows became four; 1200 px
  1341 to 1263. Nine minutes and $4.77.
- `every-line-is-one-line` (capability 5), round 7, PR #131. See
  `rounds/007.md`. Every line of the tree is one line at both widths;
  facts drop from the right and the state word never drops; the marks are
  characters and the working mark turns through a measured cycle. **390 px
  1659 → 1137: the completion condition holds by 63 px.** The round asked
  twice and the second answer reversed round 6's foreman call.
- `the-page-says-what-the-spend-bought` (capability 7), round 6, PR #130.
  See `rounds/006.md`. `VALUE`, `WHERE` with four groupings, `MODELS`,
  `LEAKS`, and the cache share off every heading. `WHERE` and `MODELS`
  fold at 390 px behind a summary line; `VALUE` does not. The crew
  corrected the research four times and stopped at the completion
  condition rather than shipping past it.
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

None until the human answers. Every capability is done, including the
one they added after seeing the result.

The foreman recommends **done**. All nine conditions in `goal.md` hold on
`main`, including condition 6: the 390 px page is **1002 closed, 1114
with every fold open**, against its 1200.

Five proposals wait, all listed above and none blocking. Two are
sentences in the frozen `design-foundation.md` that round 7's two answers
changed in behaviour; ratifying them makes the contract match the page.

To reopen: set `Status: active`, write a queue, and set
`Round: 0 of 3 in this budget (fourth budget)`.
