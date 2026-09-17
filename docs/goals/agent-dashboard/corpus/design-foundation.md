# Design foundation

Approved by: pending. Frozen once approved.

A visual specimen of this file, with every scale and component drawn on
the product's own ground and every number read from the live daemon:
https://claude.ai/code/artifact/31ebf9e5-f5eb-403c-945c-af04c28bebcf

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

A workspace that holds one project shows no heading of its own; the
project stands at the top level. That rule is already shipped and stays.

A task's state comes from one place each:

| State | Source |
|---|---|
| working | a live session carries `task:<slug>` and `goal:<slug>` |
| pending | the slug appears in `## Queue` |
| done | the slug appears in `## Done` |
| failed | the slug appears in `## Failures` |

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

### Then the tree

The whole fleet, four levels, one line each. This is the page's body and
it is what a reader scrolls.

### Then the folds

Archived sessions and done goals, closed.

## Components

Eight. Nothing else is added without a change to this file. Every class
name carries its component's prefix, which replaces the 100 ad-hoc names
the page has today with about 30.

| Component | Prefix | What it is |
|---|---|---|
| Band | `band-` | the fixed top row of counts |
| Meter | `meter-` | a labelled text-cell bar with a value and a note |
| Series | `series-` | one bar a day, with an axis and a headline |
| Tree | `tree-` | the nested disclosure holding every level |
| Line | `line-` | one row: mark, name, facts, time, actions |
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
- **facts**: state word, cost, cache share, round counter. Each drops
  from the right as the line narrows, in that order, so the state word
  is the last fact to go.
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
