# Plan: landing-page

## The floor

| Check | Command | Pass condition |
|---|---|---|
| HTML | `npx html-validate site/index.html` (or `tidy -q -e`) | 0 errors |
| Render | headless Chromium opens `site/index.html` at 1200 and 390 | no console error, no horizontal scroll |
| Contrast | the crew's script over every colour pair the page paints | text ≥ 4.5:1, marks ≥ 3:1 |

## What the design established

- One file, `site/index.html`, as today: inline CSS and one inline
  script. The tokens are the dashboard's, copied as CSS custom
  properties from the `.pen` variables: `bg #050c10`, `surface
  #0e1d25`, `border #264653`, `text #e8eef0`, `muted #a7b8bf`, `faint
  #82969e`, `accent #2a9d8f`, `success #52b788`, `warning #e9c46a`,
  `danger #e76f51`, `caution #f4a261`; the five space steps 4/8/12/16/24;
  JetBrains Mono.
- Type: the hero headline 40 px at 1200 and 28 px at 390; section
  headings 24 / 20; the tiles' figures 32 / 24; everything else 18, 13
  and 12. Weight 600 for headings and names, 400 elsewhere.
- Pages: each section `min-height: 100vh`, `scroll-snap-align: start`
  on a `scroll-snap-type: y mandatory` scroller; content in a centred
  column, `max-width: 880px`, with 64 px above and below at 1200 and
  16 px gutters at 390; a hairline between pages.
- Entrance: an `IntersectionObserver` at 40 % marks a page `shown`
  once; its column's children go from opacity 0 and translateY 8 px
  to rest over 240 ms ease-out, 60 ms apart in document order; under
  `prefers-reduced-motion` no transform and no delay.
- Marks: the `◐` glyph cycles `◐ ◓ ◑ ◒` at 90 ms; the `█` cursor blinks
  at 530 ms; both stop under reduced motion.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **The page is the frames.** `site/index.html` reproduces `Landing 1200` and `Landing 390`: the band, the hero, the six pages with their specimens, the footer; the copy control and the open link keep today's behaviour. | Screenshots at 1200 and 390 beside the exports; the HTML and render floor; the contrast script's table in the note. |
| 2 | **The page moves as the notes say.** Snapping, the staggered entrance once per page, the turning mark, the blinking cursor, all off under reduced motion. | A headless-Chromium script that scrolls page by page and samples opacity and the mark glyph over time, with reduced motion on and off; its output in the note. |

Capability 1 first; 2 builds on its DOM.
