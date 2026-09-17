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

## The decision: the brand green, brightened

The human said the green still looked wrong. Measuring twelve greens in
OKLCh says why, and the answer is not the hue.

**`#3fb950` is the darkest but one and the third-least saturated green of
the twelve.** L* 69.5 and chroma 0.181. A green that is both dark and
low-chroma on a near-black ground reads muddy, and the day chart is a
large field of it, which is where that shows most.

| Green | Hex | L* | Chroma | Contrast on `#0d1117` |
|---|---|---:|---:|---:|
| **Spring — picked** | `#2ee66b` | 81.2 | **0.218** | 11.40 |
| Material A400 | `#00e676` | 81.0 | 0.214 | 11.34 |
| Vivid | `#00e05a` | 79.1 | 0.230 | 10.64 |
| Neon | `#00ff88` | 87.6 | 0.228 | 14.11 |
| Tailwind 400 | `#4ade80` | 80.0 | 0.182 | 10.86 |
| GitHub, the site's | `#3fb950` | 69.5 | 0.181 | 7.45 |
| Emerald 400 | `#34d399` | 77.3 | 0.153 | 9.84 |

**Spring `#2ee66b` is the most saturated green that is not glare.**
Above L* 85 a large fill starts to glare — Neon and Phosphor both do,
and the chart is the largest accent field on the page. Spring holds the
chroma at a lightness that does not.

The hue stays where the brand put it: 149°, still 106° from the amber of
needs-you and 158° from the red of failed. Everything else about the
palette is unchanged.

Light theme: `#2ee66b` reads 1.6 on white, so the light accent is
`#0a7f3f`, which reads 5.10 on the ground and 4.79 on the surface.

### One thing for the human

**`site/index.html` still sets `--accent: #3fb950`.** The dashboard and
the site are no longer the same green. Either the site takes `#2ee66b`
too — a one-line change, and the favicon's two `stroke="#3fb950"`
attributes with it — or the tie between them is structural rather than
exact. The foreman proposes the first and has not made it.

## Where the green came from: the palette kitterm already has

The human asked what colour the landing page uses. It uses a defined
one, and looking there settled the question that two rounds of
invention had not.

**`site/index.html` sets `--accent: #3fb950`.** That green is the
favicon's chevron and pipe, the blinking caret beside the headline, and
`Web/terminal/src/favicon.ts` calls the same value `connected`. The
landing page's whole ground is already the page's ground: `--bg
#0d1117`, `--panel #131922`, `--line #232b36`, `--fg #e6edf3`, `--muted
#9aa5b1`, `--dim #6e7681`.

**The dashboard never needed a new hue. It needed to stop spending
green on two things.** `tokens.css` binds `--ui-success` to the same
`#3fb950`, so green means both "kitterm" and "done".

### The rule that frees it

**Colour marks what needs attention. A finished thing is grey.**

A done task is history. It needs nothing from the reader, so it does not
earn a colour — a grey `✓` says it. The same holds for pending and for
idle. That leaves three hues, not four:

| State | Colour | Why it is coloured |
|---|---|---|
| working | `#3fb950` the brand green | it is alive; this is the caret's colour |
| needs you | `#fbbf24` amber | it is blocked on a person |
| failed | `#fb7185` red | it is broken |
| done, pending, idle | grey | they need nothing |

Three hues sit at 128°, 43° and 351°. **The closest pair is 52°, the
widest of any palette drawn**, and it is wide for a reason that is not
luck: there are fewer colours competing.

Both themes measured, on the ground and on the surface: zero failures.
The dark values are the landing page's own.

| Token | Dark, from `site/index.html` | Light |
|---|---|---|
| `bg` | `#0d1117` | `#ffffff` |
| `surface` | `#131922` | `#f6f8fa` |
| `border` | `#232b36` | `#d0d7de` |
| `text` | `#e6edf3` | `#1f2328` |
| `muted` | `#9aa5b1` | `#4d5560` |
| `faint` | `#7d8794` | `#5f6873` |
| `accent` | `#3fb950` | `#1a7f37` |
| `warning` | `#fbbf24` | `#8a5a00` |
| `danger` | `#fb7185` | `#c8102e` |

One value moved: `faint` lifted from the landing page's `#6e7681` to
`#7d8794`, because `#6e7681` reads 4.19 on the surface and a text pair
needs 4.5.

## Superseded: round two, not cyan, not purple

The human ruled out cyan on 2026-09-17, after ruling out violet the same
day. That closes most of the wheel.

**The accent has to stay clear of green, amber and red**, because those
three carry state and a mark is one character. Cyan and violet are out.
What is left is the yellow-green band, the magenta band, or no hue at
all. Three candidates, drawn as the same strip in the `Palettes` frame:

| | Accent | Closest hue pair | Accent to nearest state | Lowest contrast |
|---|---|---|---|---|
| **Lime** | `#a3e635` chartreuse | 40° (accent/warning) | 40° | **5.20** |
| **Rose** | `#f472b6` magenta | **31°** (accent/danger) | 31° | 5.06 |
| **Mono** | `#f2f4f7` no hue | 52° (warning/danger) | **not a hue** | 5.20 |

**Mono wins the measurement outright.** Its accent has no hue, so it
cannot be confused with a state at any size — the strongest separation
available, and it is not a compromise but a different idea: bars and the
spinner are white, text is grey, and colour appears *only* on a state
mark. That makes every coloured thing on the page meaningful.

**Lime is the bold one.** Chartreuse on near-black is the industrial
terminal look, shifted yellow so it never reads as the green of done.
Its 40° to the warning amber is the number to look at on the strip.

**Rose is the most distinctive and the weakest.** 31° from the red of
failed is close for two marks in the same column.

The human picks. Every frame draws from the document variables, so the
re-tint is one edit whichever they take.

## Superseded: Carbon, before the landing page was read

**Carbon, under rule C.** The human ruled out violet on 2026-09-17, so
Flux is not taken despite the best numbers, and Carbon is the pick.

**Excluding violet, the accent had to be cyan or blue.** It has to stay
clear of green, amber and red, which leaves one band of the wheel. Four
candidates were measured inside it:

| | Accent | Ground | Closest hue pair | Accent to nearest state | Lowest contrast |
|---|---|---|---|---|---|
| **Carbon** | `#22d3ee` cyan | `#0a0a0b` true black | 46° | 46° | **5.20** |
| Ink | `#60a5fa` azure | `#0a1020` navy | 52° | 55° | 5.20 |
| Dune | `#2dd4bf` teal | `#12100e` warm black | **27°** | 89° | 5.06 |
| Phosphor | `#7bff9e` green | `#080a09` | 39° | 52° | 5.04 |

**Dune is rejected on a number**: its warning orange sits 27° from its
danger red, and two marks a reader cannot tell apart is a worse failure
than any ratio.

**Ink has the better separation and Carbon is taken anyway.** Ink's
azure is 213°, one degree from the blue the page already had, so it
would read as the same palette on a slightly different ground. Carbon's
cyan on a true-black ground is the visible change the human asked for,
and 46° is the same separation Signal would have given.

Every frame in `dashboard.pen` is re-tinted: the document variables hold
Carbon and each frame draws from them, so the re-tint was one edit
rather than six.

- Violet is the widest hue any accent can take from green, amber and
  red at once, so it never competes with a state.
- It reads as machine rather than as status, which is what an accent on
  a bar and a spinner should read as.
- Its ground is warmed a touch off pure black, `#0c0c12`, so the violet
  does not sit on a dead ground.

**Phosphor** was the boldest and is not taken. Its cost was real:
success stops being green.

## Carbon, as shipped

Two themes, both measured. Every text pair clears 4.5 and every state
pair clears 3.0, on the ground and on the surface.

| Token | Dark | Light |
|---|---|---|
| `bg` | `#0a0a0b` | `#fcfcfd` |
| `surface` | `#111113` | `#f4f4f6` |
| `border` | `#1f1f23` | `#e0e1e4` |
| `text` | `#e9eaec` | `#16171a` |
| `muted` | `#aeb0b6` | `#4b4d55` |
| `faint` | `#7e8189` | `#63666e` |
| `accent` | `#22d3ee` | `#0e7490` |
| `success` | `#4ade80` | `#15803d` |
| `warning` | `#fbbf24` | `#9a6400` |
| `danger` | `#fb7185` | `#be123c` |

Fourteen pairs measured in each theme, on the ground and on the surface.
Zero failures: every text pair clears 4.5 and every state pair clears
3.0.

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
