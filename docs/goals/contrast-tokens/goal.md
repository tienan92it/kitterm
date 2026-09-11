# Goal: every text the pages print is readable on every theme

## Objective

`--ui-text-muted` mixes the text colour 66 percent toward the background,
which lands under the WCAG 4.5:1 minimum on ten of the sixteen bundled
themes. Two accessibility reviews found it, in rounds 5 and 7 of
`projects-and-knowledge`, and both deferred it: the token sits outside
any one goal's diff, and `theme-contrast.test.ts` carries a
`KNOWN_BELOW` table that names the failures instead of fixing them.

The same reviews found that the test only measures the pairs someone
remembered to list. A new element's colours are unmeasured until a
reviewer notices, which is how the proposals chip and the goal meta line
each shipped under the bar.

## Exclusions

- No new theme, and no change to a theme's own colours. Only the token
  mixes derived from them.
- No change to the terminal grid's colours, which the themes own and
  xterm.js renders.
- No redesign. Sizes, weights, and layout stay as they are. The surface
  elevation is not a redesign for this purpose: the human opened it on
  2026-09-11, because it is the lever that actually holds the page under
  the floor. A round may change what lifts `--ui-surface`,
  `--ui-surface-2`, `--ui-hover` and `--ui-active` off `--ui-bg`, and the
  `.pane-close` opacity at `styles.css:469`. Every other size, weight and
  layout still stays.
- No dropping a theme that cannot pass; if one cannot, it is recorded
  with its measured ratios and the human decides.

## Completion condition

All four hold:

1. Every text-and-background pair the two pages actually use passes
   4.5:1, or 3:1 where the text is large by the WCAG definition, on every
   bundled theme, **except where the theme's own colours put it out of
   reach**. A theme paints its own foreground on its own background, and
   this goal does not change either. `synthwave-84` reads 4.31 there, so
   no token mix can carry it. (`solarized-dark` reads 4.75 and passes;
   round 5 corrected the foreman's earlier claim.)
2. `theme-contrast.test.ts` derives the pairs from the stylesheets rather
   than a hand-written list, so a new element is measured the day it is
   written.
3. `KNOWN_BELOW` is a ratchet, not an escape hatch. It can shrink and it
   cannot grow: a pair that is not already listed and fails the floor
   fails the build, and a listed pair that starts passing fails the build
   until its entry goes. Every entry names the lever that would clear it,
   or says that only a theme's own colours could.
4. The floor is green and `main` is green after the merge.
