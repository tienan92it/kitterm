# Design foundation

Approved by: pending. Frozen once approved.

The design is drawn in Pencil. Save the open document as
`corpus/dashboard.pen` beside this file; it holds four frames, and every
number in them is read from the live daemon on 2026-09-17:

| Frame | What it shows |
|---|---|
| `Dashboard 1200` | the whole page at desktop width, 28 px lines, the by-model split, the yield block, where the dollar goes, the leaks |
| `Dashboard 390` | the same page on a phone, 44 px lines, facts dropped, the yield block kept |
| `Foundation` | the space scale, the type scale, the state marks, the two densities, the model naming rule |
| `Anatomy of a line` | the line's six cells and the order its facts drop in |
| `Value groupings` | the `VALUE` panel at each of its four groupings, with real rows |

Exports of the four frames sit beside this file as `01-*.png`. A written
specimen of the same contract, with the before-image and the
measurements, is published at
https://claude.ai/code/artifact/31ebf9e5-f5eb-403c-945c-af04c28bebcf

The Pencil document defines the tokens as document variables, so a round
reads them from the file rather than from this prose: ten colours on a
`theme` axis with `dark` and `light`, five space steps, three type sizes,
two line heights, and the mono family.

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
   gradient, no transition, no icon font.
5. **Colour marks state and nothing else.** Text is one of three greys.
   The four semantic colours appear on the one-character mark at the
   start of a line, and nowhere else.

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

| State | Source |
|---|---|
| working | a live session carries `task:<slug>` and `goal:<slug>` |
| pending | the slug appears in `## Queue` |
| done | the slug appears in `## Done` |
| failed | the slug appears in `## Failures` |

## The model

An agent's model is a fact of its line, and the spend splits by model in
the meters. Both come from data that is already on disk.

**A live session's model** comes from the last `"model"` field in its
`agentTranscript`, which the session payload already carries. Measured on
2026-09-17 over the 40 most recent transcripts: a 4 KiB tail read is
enough, and 40 reads of a 64 KiB tail cost 10 ms in total, 0.25 ms each.
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

No new colour. Four semantic tokens already exist and already pass the
contrast ratchet on every bundled theme:

`--ui-accent` working · `--ui-warning` needs you · `--ui-danger` failed ·
`--ui-success` done.

They paint the mark glyph. They never paint text, a background, or a
border.

## The frame

### Top band — fixed height, four cells

```
┌──────────────────────────────────────────────────────────────┐
│ kitterm            2 working   4 need you   $2,316 30d   19% │
└──────────────────────────────────────────────────────────────┘
```

One row, one height, always. Each cell is a count and its noun. The
"need you" cell is a link that scrolls to the first marked line; it is
not a list. This replaces 619 px of stacked paragraphs with one row.

Below 768 px the four cells wrap to two rows of two. The height is still
fixed, because the cells are fixed.

### Then the meters

The usage series and the quota bars, side by side above 768 px, stacked
below it. Both are the `meter` and `series` components.

### The panels

Everything that is a measure rather than a session sits in one stack of
panels between the band and the tree. Each panel is one row: a label in
an 84 px gutter on the left, its content filling the rest. The gutter
gives the whole stack one rhythm, and it is what makes five panels read
as a dashboard rather than as five lists.

| Panel | Content |
|---|---|
| `USAGE` | the range's spend and tokens, the day chart, the axis, the apportionment note |
| `QUOTA` | one bar per window, its percentage and its reset |
| `VALUE` | a grouping selector, then one row per group: name, bar, spend, unit count, unit cost |
| `MODELS` | one bar per model, scaled to spend, with the spend and the session count |
| `LEAKS` | one line per leak, marked |

### The VALUE panel groups by the same levels as the tree

`VALUE` and `WHERE` were two panels asking one question at two fixed
groupings. They are one panel with a selector, and the groupings are the
levels the page already has:

| Grouping | A row is | Its spend comes from | Its units come from |
|---|---|---|---|
| **project** | a registered project | the daily rollup, keyed on the transcript's cwd | that repository's merged pull requests and lines |
| **goal** | a goal folder | the sum of the `- Cost:` line of its round records | the pull requests those records name |
| **task** | a queue item, which is one round | that round's `- Cost:` line | the pull request that round's record names |
| **role** | a crew in a worktree, or a session in a root | the transcript's own directory | that role's lines and API hours |

Two rules the panel holds at every grouping.

**A row with no source prints a dash, never a zero.** 37 of 51 round
records carry no `- Cost:` line, so most goals and tasks have no spend,
and most rounds name no pull request.

**The unattributed remainder is a row, not a footnote.** At the `goal`
grouping, `no round record` is $832.89, which is 85% of kitterm's 30-day
spend, and it draws as the longest bar in amber. Hiding it would make
the other three rows look like the whole picture.

Below 768 px the gutter goes and each panel's label becomes a small
heading over its content. `VALUE` keeps its selector and its rows.
`LEAKS` drops: it is the least urgent measure, and the same rule governs
it as governs a line's facts.

`corpus/valuemaxxing.md` holds the measurements and the reason each row
is there.

### Then the tree

The whole fleet, four levels, one line each. This is the page's body and
it is what a reader scrolls.

### Then the folds

Archived sessions and done goals, closed.

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
