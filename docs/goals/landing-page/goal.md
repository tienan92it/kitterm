# Goal: kitterm.dev is the dashboard's landing page

## Objective

A person opens https://kitterm.dev on a laptop or a phone and reads,
in the dashboard's own tokens and face, what kitterm is: a terminal
daemon with a ledger. The hero says it in two lines with the install
command under it. Scrolling moves one page at a time through four
feature pages — the terminal, what the spend bought, where it went,
which model spent it — and the crew tree, each drawn as a specimen of
the real product. The design is the human's, approved on 2026-09-20:
the frames `Landing 1200`, `Landing 390` and `Landing notes` in
`../agent-dashboard/corpus/dashboard.pen`, which also holds the tokens.

## Exclusions

- No framework, no bundler, no font served from a third party but
  Google Fonts for JetBrains Mono with a system mono fallback.
- No live data: every number on the page is a specimen the frame
  draws, not a fetch.
- No analytics, no cookies, no form.
- No change to the terminal or the fleet view; `site/` only.

## Completion condition

All six hold on a build from `main`, served by Cloudflare Pages:

1. At 1200 px the page matches `Landing 1200` page for page: the
   band, the centred hero, six snapping viewport pages, the footer.
2. At 390 px it matches `Landing 390`.
3. Scrolling snaps one page at a time; a page's content appears once,
   staggered, as `Landing notes` says; under reduced motion it is
   simply there.
4. The `◐` marks turn at 90 ms and the pane cursor blinks; nothing
   else moves.
5. The install command copies to the clipboard and the copy control
   says so; `Open my terminal ↗` opens `http://kitterm.localhost:3418/`
   as today.
6. Lighthouse accessibility 100 and performance ≥ 95 on the deployed
   page; every colour pair the page paints clears 4.5:1 for text and
   3:1 for marks.

The floor (the site's HTML validates; the page renders in headless
Chromium at both widths with no console error) is green at every step.
