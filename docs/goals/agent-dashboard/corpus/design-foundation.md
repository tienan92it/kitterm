# Design foundation

Approved by the human on 2026-09-17, after five palette rounds and a
deeper ground. Frozen. A round that needs a different token proposes the
change in its record rather than making it.

The design is `corpus/dashboard.pen`, beside this file. It is the single
source of truth for the page: what the page looks like at 1200 px and
at 390 px is what its two `Dashboard` frames draw, and a round that
finds this prose and a frame in disagreement follows the frame and says
so in its record. The file holds six frames:

| Frame | What it shows |
|---|---|
| `Dashboard 1200` | the whole page at desktop width, 28 px lines |
| `Dashboard 390` | the same page on a phone, 44 px lines, facts dropped |
| `Foundation` | the space scale, the type scale, the state marks, the two densities, the model naming rule |
| `Anatomy of a line` | the line's six cells and the order its facts drop in |
| `Value groupings` | the `WHERE` panel at each of its four groupings, with real rows |
| `Palettes` | the palettes tried, and the one chosen, with the spinner candidates below |

The file defines the tokens as document variables, so a round reads them
from the file rather than from this prose: eleven colours on a `theme` axis
with `dark` and `light`, five space steps, three type sizes, two line
heights, and the mono family. A crew cannot open the file; the foreman
exports the frames it needs into the round's scratch directory and
names the differences in the round prompt. No export lives in this
folder.

This file is the contract between the design and every round that
implements it. A round does not invent a token, a size, or a class
prefix. It uses what is here, or it proposes a change in its record.

## Principles

Five, in order. When two conflict, the earlier one wins.

1. **A dashboard monitors. It does not accept work.** The page shows
   state and lets a reader open the thing that needs them. It has no
   text input. `Open the pane` is the way to act.
2. **The frame does not move.** The top band is always the same height
   and holds the same four facts in the same places, whatever the fleet
   is doing. A reader learns where to look once.
3. **One line, one thing.** Every line in the tree is one line: a mark,
   a name, its facts, its time. A fact that does not fit is dropped, not
   wrapped.
4. **The terminal is the idiom.** Monospace, hairlines, bracketed words,
   text-cell bars. No pill, no shadow, no radius above 2 px, no
   gradient, no icon font.

   **One thing moves, and only one.** The mark on a line whose agent
   holds the tty turns, at 90 ms a frame. It is a character cycle, not a
   CSS transition, so it costs no layout and it reads at a glance from
   across a room. Everything else is still: no fade, no slide, no
   transition on a colour or a size. Under `prefers-reduced-motion` the
   cycle stops and the mark rests full.

   **The glyph is measured, not assumed.** A missing glyph renders as a
   box, which is worse than no animation, and braille is not in every
   monospace face. The page tries three cycles in order and takes the
   first whose advance width matches the mark column: braille
   `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`, which matches the pane; quadrant `◐ ◓ ◑ ◒`;
   then the block ramp `▁ ▃ ▅ ▇`, which the chart already proves.
5. **Colour marks a state, and only on the mark.** Text is one of
   three greys. Four colours appear on the one-character mark at the
   start of a line, and nowhere else: the accent for what is alive,
   green for what is done (the human's call of 2026-09-19), amber for
   what is blocked on a person, red for what is broken. Pending and idle
   are grey, because they need nothing from the reader. A disclosure
   triangle is grey too: it is a control, not a state.

## Hierarchy

Four levels, and the indent says which.

```
WORKSPACE                         $1,249.23  98%   2 agents
  project                            $30.91  97%   1 agent
    ▸ goal                    active  r2/3    $8.61
        · task                pending
        > task                working   crew round 2      4m
        ✓ task                done      round 1  PR #118
```

| Level | Source | Identity |
|---|---|---|
| Workspace | the parent directory of a project root | its directory name |
| Project | `GET /api/projects` | its `name` |
| Goal | `GET /api/projects/<id>/knowledge` | its `slug` |
| Task | the goal's `STATE.md` sections, plus a live `task:` label | its slug |

An agent is not a fifth level. It is a session, and a session sits under
the task it runs or under its project. Its model is one of its facts;
see "The model" below.

A workspace that holds one project shows no heading of its own; the
project stands at the top level. That rule is already shipped and stays.

A task's state comes from one place each:

| State | Mark | Reads | Source |
|---|---|---|---|
| working | `◐` turning, accent | `[working]` | a live session carries `task:<slug>` and `goal:<slug>` |
| needs you | `?` warning | `[needs you]` | the agent's hook report, or a pending approval |
| pending | `•` faint | `[pending]` | the slug appears in `## Queue` |
| done | `✓` success, green | `[done]` | the slug appears in `## Done` |
| failed | `!` danger | `[failed]` | the slug appears in `## Failures` |
| idle | `–` faint | `[idle]` | a session with no agent holding the tty |
| waiting | `?` warning | `[waiting]` | a goal whose budget is spent |

**A state always reads as a bracketed word, never as a bare one.** The
brackets are the `tag` component and they are what makes a state
unmistakable in a column of names that are also lower-case and hyphenated.
The mark carries the colour; the word carries the meaning; neither
appears without the other.

The `SESSIONS` panel header prints the whole vocabulary above the tree,
so a reader never has to infer a mark.

## The model

An agent's model is a fact of its line, and the spend splits by model in
the meters. Both come from data that is already on disk.

**A live session's model** comes from the last `"model"` field in its
`agentTranscript`, which the session payload already carries. Measured on
2026-09-18 over the 40 most recent transcripts: the last assistant line
sits within 4 KiB in 3 of them, within 64 KiB in 39, within 256 KiB in
all 40, so the read is one 256 KiB tail.
37 of the 40 yielded a model; the other three had no assistant turn yet,
and a session with no model prints nothing rather than a guess.

**The spend by model** comes from each transcript's final `cost-state`
line, whose `modelUsage` map already carries `costUSD`, the three input
token kinds, and `outputTokens` per model. `TranscriptBill` reads that
map today and `UsageRollup` throws it away. Keeping it is the only
change the data needs.

### Naming

The page prints a name, not an id. The rule, in order:

1. Drop the `claude-` prefix.
2. Move a `[1m]` suffix to ` · 1M`, and keep that variant separate from
   its family. The 1M context costs more per token, which is the point of
   showing the split at all.
3. Drop a trailing eight-digit date.
4. Title-case the family and join the version digits with a dot.
5. When a step does not apply, print the id unchanged. Never guess.

| Id | Name |
|---|---|
| `claude-fable-5-1` | Fable 5.1 |
| `claude-opus-5[1m]` | Opus 5 · 1M |
| `claude-haiku-4-5-20251001` | Haiku 4.5 |

### Where it shows

- **On a session line**, in the facts, before the time. It drops before
  the state word and after the cost, as every fact does.
- **In the meters**, as one row per model under the day series: the name,
  the spend, the cache share. Measured over the last 30 days on
  2026-09-17, seven ids appear and this is what they cost.

**Not the quota.** `goal.md` of `workspace-ledger` excluded a per-model
quota row because the rate limits are not per model and no local source
carries one. That exclusion stands. Cost per model is a different fact
with a real source, and it is in.

## Tokens

### Space

One scale. No rule writes a raw pixel for space.

```css
--space-1: 4px;   /* inside a line: between a mark and a name */
--space-2: 8px;   /* between lines in a group */
--space-3: 12px;  /* one indent level in the tree */
--space-4: 16px;  /* between groups */
--space-5: 24px;  /* between the band and the tree */
```

### Type

Three sizes. Hierarchy comes from weight and colour, not from a fourth
size. 12 px is the floor: nothing a reader must read is smaller.

| Token | Size | Weight | Use |
|---|---|---|---|
| `--type-headline` | 18px | 600 | the page title, the one headline number |
| `--type-heading` | 13px | 600 | a workspace name, a project name |
| `--type-body` | 12px | 400 | everything else |

Three text colours carry the rest, and all three already exist and pass
the ratchet:

| Token | Use |
|---|---|
| `--ui-text` | a name, a value a reader acts on |
| `--ui-text-muted` | a fact beside a name: a state word, a cost |
| `--ui-text-faint` | a time, a unit, a qualifier |

### Density

Two modes, chosen by width, never by a control. The 44 px tap target
(WCAG 2.2 SC 2.5.8) is a touch rule; a pointer does not need it.

```css
--line-h: 44px;                    /* below 768px */
@media (min-width: 768px) { --line-h: 28px; }
```

Every interactive target below 768 px is 44 px tall. Above it, 28 px.

### Colour

**The page inherits the ground and owns the accents.** `bg`, `surface`,
`border` and the three text greys keep deriving from the terminal's
theme, so the page sits in its world and a light terminal still works.
The four colours that carry meaning are the page's own constants,
chosen for hue separation rather than inherited by accident.

`corpus/palette.md` holds the measurements. The human chose the Coolors
palette on 2026-09-17 and amended it on 2026-09-19; the values are the
`dashboard.pen` variables and this table repeats them:

| Role | Dark | Light | Where |
|---|---|---|---|
| `accent` working, bars | `#2a9d8f` | `#1d7268` | the working mark, every bar, the quota fill under 80% |
| `success` done | `#52b788` | `#2d6a4f` | the `✓` mark |
| `warning` needs you | `#e9c46a` | `#8a6415` | the `?` mark, the unattributed WHERE row |
| `danger` failed | `#e76f51` | `#b0472c` | the `!` mark |
| `caution` quota high | `#f4a261` | `#b8641f` | the quota fill and its percentage at 80% and over |

They paint a mark: a glyph, a bar, the tile's rule, or the one run of
text that carries a state. They never paint a background or a border.

## The frame

The two `Dashboard` frames in `dashboard.pen` are the layout: the band,
the panels with their label gutter, the tree, the folds, and what each
keeps and drops at 390 px. This file does not describe the layout a
second time. Three rules the frames cannot carry:

- **A panel's note is one line, and it names a fact.** Not a paragraph,
  not a caveat with a reason attached. The reasoning lives in
  `corpus/valuemaxxing.md` and in the round records; the page carries
  the number.
- **A row with no source prints a dash, never a zero.** Most goals and
  tasks have no `- Cost:` line, and most rounds name no pull request.
- **The unattributed remainder is a row, not a footnote.** `no round
  record` draws as the longest bar, in amber, at the goal grouping.
  Hiding it would make the other rows look like the whole picture.

## Components

Ten. Nothing else is added without a change to this file. Every class
name carries its component's prefix, which replaces the 100 ad-hoc names
the page has today with about 30.

| Component | Prefix | What it is |
|---|---|---|
| Band | `band-` | the fixed top row of counts |
| Meter | `meter-` | a labelled text-cell bar with a value and a note |
| Series | `series-` | one bar a day, with an axis and a headline |
| Tree | `tree-` | the nested disclosure holding every level |
| Line | `line-` | one row: mark, name, facts, time, actions |
| Split | `split-` | one row per model or role: name, bar, spend, rate |
| Yield | `yield-` | what the range's spend bought: a count, a unit, a unit cost |
| Fold | `fold-` | a closed group with a count |
| Tag | `tag-` | a bracketed word: `[new]`, `[done]`, `[PR #118]` |
| Note | `note-` | a paragraph of explanation under a block |

### The line, in detail

Every level of the tree is one `line`. Its cells, in order:

```
[mark] [indent] [name] [facts…] [time] [actions]
  1ch    n×3     grow    auto     auto    auto
```

- **mark**: one character, coloured by state, or blank.
- **indent**: `--space-3` per level below the top.
- **name**: the only cell that grows, and the only one that truncates.
- **facts**: state word, cost, model, round counter. Each drops from the
  right as the line narrows, in that order, so the state word is the
  last fact to go and the model goes before the cost.

  **The cache share is not a fact column.** It sat on every heading and
  `corpus/valuemaxxing.md` measured it at 95–99% on every session over
  $5 but three. A constant carries no information. It appears only when
  a project or a goal falls below 95%, as one exception line under the
  leaks block.
- **time**: relative, always the same width.
- **actions**: `[new]`, the `…` menu, or nothing.

## What the page removes

| Removed | Why |
|---|---|
| Every text input | Principle 1. The page monitors; it does not accept work. `POST /api/sessions/<id>/input` keeps working for the MCP bridge and the pane. |
| The strip as a list of paragraphs | Principle 2. It becomes one band cell and marks on the lines themselves. |
| The reply field, the `[send]` control, and the held-reason text | Principle 1. |
| 12 px of body text at four different sizes | The type scale is three sizes. |
| 100 class names | The component set is eight prefixes. |

## What the page keeps

Every accessibility rule earlier rounds paid for, without exception:

- a `data-focus` key on every control, restored across repaints;
- the three live regions: `announce` polite, `noticeLine` alert,
  `restartLine` status;
- 44 px tap targets below 768 px;
- one column at 390 px, no horizontal scroll;
- the pure-model split: `sessions-model.ts` decides, `sessions.ts`
  paints, and no model function reads the clock;
- the contrast ratchet, which may shrink and may not grow.

## How a round proves it followed this file

Each round ships all four:

1. a vitest over the model it changed;
2. a `sessions-css.test.ts` assertion for any token or absence this file
   names;
3. a screenshot at 390 px and at 1200 px, against the **real**
   `docs/goals/` tree, not only a fixture;
4. the page height at both widths, before and after.
