# STATE: agent-dashboard

- Status: done
- Round: 2 of 3 in this budget (seventh budget)
- Rounds total: 20
- Last floor: green (2026-09-21, round 20 after: vitest 1463 in 59 files)
- Updated: 2026-09-21, round 20 closed, done

## Queue

Empty.

## Failures

None.

## Proposals waiting on the human

- A user with no transcript at all sees USAGE at $0 and an empty
  MODELS panel; the first-run frame does not draw that case. One line
  each, drawn first, if wanted. See `rounds/020.md`.
- `Sources/KittermDaemon/ModelPricing.swift` is a rate table copied from
  platform.claude.com on 2026-09-20; nothing updates it. Own it, or
  move the rates to a file. See `rounds/016.md`.
- Read `<session>/subagents/*.jsonl` into the running estimate; a
  session with subagents estimates up to 17% under. One round.
- `site/index.html` sets `--accent: #3fb950`; the landing redesign in
  `dashboard.pen` (frames `Landing 1200`, `Landing 390`, `Landing
  notes`) replaces it when the human approves.
- `goal.md` condition 6 says the 390 px page is under 1200 px. The
  design measures about 2500 on the real tree. Reset the number or
  strike the condition.

## Done

- `the-first-run-state`, round 20, `64491e2`, PR #143. See
  `rounds/020.md`. Each empty panel names the command that fills it.
- `the-bill-behind-trailing-lines`, round 19, `5db4a60`, PR #142. See
  `rounds/019.md`. A bill behind Claude Code's trailing records is a
  bill; the rollup re-bills what it skipped: $184.49 more on 30 days.
- `a-window-is-never-dropped`, round 18, `2166959`, PR #142. See
  `rounds/018.md`. A quota window keeps its last value and time when a
  post omits it.
- `quota-resets-at-a-time`, round 17, `fbe03ce` on PR #134. See
  `rounds/017.md`. The reset cell prints a local clock time.
- `a-running-session-has-a-cost`, round 16, `f97e397` on PR #134. See
  `rounds/016.md`. A running session prints `~$16.26` from its
  transcript, 1–3% under the bill it becomes.
- `cost-column-and-pr-links`, round 15, `23a30a4` on PR #134. See
  `rounds/015.md`. The tree's number column is the cost at every level;
  `PR #N` links to GitHub through `pullRequestBase` on `/api/projects`.
- `four-defects-from-review`, round 14, `ef0e941` on PR #134. See
  `rounds/014.md`. Stale quota wording, the quadrant spinner alone,
  fold rows on the baseline, done goals in the fold open to their tasks.
- `every-figure-follows-the-range`, round 13, `eb0a6bb` on PR #134. See
  `rounds/013.md`. Two figures did not follow the range (a goal's tree
  cost, LEAKS) and now do; the rest already did. Task working time back;
  every goal listed.
- `where-columns-per-filter`, round 12, `6432dae` on PR #134. See
  `rounds/012.md`. The WHERE count and pull-request cells read per
  filter as the Components frame draws them.
- `the-approved-adjustments` (capability 11), round 11, PR #134. See `rounds/011.md`. The page reproduces the design the human
  approved on 2026-09-19 at both widths; 16 assertions added, 6
  replaced under charter, the ratchet untouched.
- Corpus cleanup, 2026-09-18, at the human's direction: `dashboard.pen`
  is the single source of truth. Every rendering of the design left the
  corpus (`01-*`, `02-*`, `03-*`, `04-*`); `design-foundation.md` points
  at the file and no longer describes the layout twice; its working
  mark and its transcript-read sentence carry the measured values; and
  `valuemaxxing.md` carries round 6's four corrections as an amendment.
  Four proposals closed by that: the two folding sentences (the frames
  decide), the 4 KiB sentence, the four numbers.
- `the-page-is-the-pen-design` (capability 10), round 10, PR #134. See `rounds/010.md`. The page reproduces
  the two frames at 1200 and 390; `Others` is the last MODELS row. 27
  assertions added, the shipped-shape assertions replaced under charter,
  the ratchet untouched. 390 px is 2499 on the real tree: the frame's
  shape, above `goal.md`'s 1200 condition by the human's direction.
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

## Direction, continued

2026-09-18: the human closed Pen without saving after the foreman
replaced the two dashboard frames with a copy of the shipped page. The
frames are the human's design and the foreman does not edit them. The
human then said the shipped page is wrong: it must follow the Pen frames
exactly, and the one change to the frames is `MODELS` as the top three
plus `Others`. Two of the open proposals fall to this direction: the
frames show `VALUE` unfolded at 390 px, and they show a done goal's last
done tasks open at both widths. It is capability 10.

## Next action

None. Twenty rounds. Merge PR #143. Seventeen rounds, PRs #125–#134, released as v0.30.0 and v0.31.0.
The page is the human's design in `corpus/dashboard.pen`. Four
proposals wait above; to reopen for one, set `Status: active` and
write it as the queue.
