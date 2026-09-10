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
- No redesign. Sizes, weights, and layout stay as they are.
- No dropping a theme that cannot pass; if one cannot, it is recorded
  with its measured ratios and the human decides.

## Completion condition

All four hold:

1. Every text-and-background pair the two pages actually use passes
   4.5:1, or 3:1 where the text is large by the WCAG definition, on every
   bundled theme in both polarities.
2. `theme-contrast.test.ts` derives the pairs from the stylesheets rather
   than a hand-written list, so a new element is measured the day it is
   written.
3. `KNOWN_BELOW` is empty and its mechanism is deleted.
4. The floor is green and `main` is green after the merge.
