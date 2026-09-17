# Research: a palette with more character

Measured 2026-09-17. Every contrast ratio below was computed against the
five bundled terminal themes, not estimated.

## The fork the human has to answer

The page's colours derive from the terminal's theme today: `--ui-bg`
from `--term-bg`, `--ui-accent` from `--term-accent`. That is honest and
costs nothing to maintain, and it is also why the page has no character
of its own — it is whatever GitHub Dark is.

Three ways out, and only the third keeps both properties:

| | The page inherits | The page owns | What it costs |
|---|---|---|---|
| **A. Keep inheriting** | everything | nothing | no character, ever |
| **B. Own it all** | nothing | everything | the page stops matching the pane beside it |
| **C. Inherit the ground, own the accents** | `bg`, `surface`, `border`, the three text greys | the four state colours | one rule to explain |

**C is the recommendation.** The ground still follows the terminal, so
the page sits in its world and a light theme still works. The four
colours that carry meaning become page-owned constants, chosen for hue
separation rather than inherited by accident.

## The three candidates

Each is drawn as the same strip in the `Palettes` frame: the band, the
day chart, and one line per state.

| | Accent | Success | Warning | Danger | Ground |
|---|---|---|---|---|---|
| **Signal** | `#22d3ee` cyan | `#4ade80` | `#fbbf24` | `#fb7185` | `#0b0f14` cooled |
| **Flux** | `#a78bfa` violet | `#34d399` | `#fbbf24` | `#f87171` | `#0c0c12` warmed |
| **Phosphor** | `#7bff9e` green | `#22d3ee` cyan | `#ffb020` | `#ff6b6b` | `#080a09` |

## Contrast, on every bundled theme

Lowest ratio each palette reaches, across `github-dark`, `one-dark`,
`solarized-dark`, `synthwave-84` and `dracula`:

| Palette | Lowest pair | Ratio |
|---|---|---|
| current | danger on `one-dark` | **4.18** |
| Signal | danger on `one-dark` | **5.20** |
| Flux | danger on `one-dark` | **5.06** |
| Phosphor | danger on `one-dark` | **5.04** |

All three clear 3.0 everywhere, and every one of them beats the current
palette's weakest link. None needs a `KNOWN_BELOW` entry.

## Hue separation, which matters more at 12 px

A mark is one character. Two marks the reader cannot tell apart is a
worse failure than a low ratio, so the closest pair of hues is the
number to rank on:

| Palette | Hues | Closest pair |
|---|---|---|
| current | 212 · 128 · 41 · 3 | 38° |
| Signal | 188 · 142 · 43 · 351 | 46° |
| **Flux** | 255 · 158 · 43 · 0 | **43°, and the accent sits 97° from its nearest state** |
| Phosphor | 136 · 188 · 39 · 0 | 39° |

**Flux wins the number that counts.** Its accent is violet, which no
state uses, so the working mark and the bars never read as a state. In
Signal the cyan accent sits 46° from the success green; in Phosphor the
accent *is* green and success has to move to cyan, which inverts a
mapping every reader already knows.

## The decision

**Flux, under rule C.** The human picked it on 2026-09-17, and every
frame in `dashboard.pen` is re-tinted: the document variables now hold
Flux, and each frame draws from them, so the re-tint was one edit rather
than six.

- Violet is the widest hue any accent can take from green, amber and
  red at once, so it never competes with a state.
- It reads as machine rather than as status, which is what an accent on
  a bar and a spinner should read as.
- Its ground is warmed a touch off pure black, `#0c0c12`, so the violet
  does not sit on a dead ground.

**Phosphor** was the boldest and is not taken. Its cost was real:
success stops being green.

## Flux, as shipped

Two themes, both measured. Every text pair clears 4.5 and every state
pair clears 3.0, on the ground and on the surface.

| Token | Dark | Light |
|---|---|---|
| `bg` | `#0c0c12` | `#fbfbfe` |
| `surface` | `#14141d` | `#f2f2f8` |
| `border` | `#23232f` | `#dcdce8` |
| `text` | `#eaeaf2` | `#17171f` |
| `muted` | `#b0b0c0` | `#4d4d61` |
| `faint` | `#81819a` | `#68687f` |
| `accent` | `#a78bfa` | `#6d3ee8` |
| `success` | `#34d399` | `#047857` |
| `warning` | `#fbbf24` | `#a35a00` |
| `danger` | `#f87171` | `#c81e34` |

One value moved after the first measurement: `faint` on `surface` in
light read 4.37, under the 4.5 a text pair needs, so it darkened from
`#6f6f88` to `#68687f` and reads 4.86.

Under rule C the product keeps deriving `bg`, `surface`, `border` and
the three greys from the terminal's theme. The table's ground values are
what the design file draws and what the page falls back to when no
terminal theme is set.

## The spinner glyph

`design-foundation.md` names a braille spinner because that is what
Claude Code turns in the pane. Braille is not in every monospace face,
and a missing glyph renders as a box, which is worse than no animation.

**The page tries three in order and takes the first whose advance width
matches the mark column:**

1. braille `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` — matches the pane;
2. quadrant `◐ ◓ ◑ ◒` — Geometric Shapes, far wider coverage;
3. the block ramp `▁ ▃ ▅ ▇` — the chart already proves it renders.

The round measures each candidate with a canvas advance-width check in
the page's own font stack and pins the result in a test. It does not
guess, and it does not ship a box.
