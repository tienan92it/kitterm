# STATE: landing-page

- Status: active
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-20, round 2 after: html-validate 0 errors, Chromium clean, Lighthouse 95/100/100/100)
- Updated: 2026-09-20, round 2 closed, PR open

## Queue

Empty. Both capabilities are on the PR.

## Failures

None.

## Proposals waiting on the human

- Self-host JetBrains Mono in `site/` (or preload it): the Google Fonts
  stylesheet costs about 990 ms of first paint and holds Lighthouse
  performance at 95. See `rounds/002.md`.

## Done

- `the-page-moves-as-the-notes-say` (capability 2), round 2, `d153ff6`.
  See `rounds/002.md`. The staggered entrance, the turning marks, the
  blinking cursor, all off under reduced motion; Lighthouse 95/100/100/100.
- `the-page-is-the-frames` (capability 1), round 1, `f311485`. See
  `rounds/001.md`. The page reproduces the two frames; 16 colour pairs
  pass; copy works.

## Direction

2026-09-20: the human asked for the landing page redesigned on the
dashboard's design system — minimalism, clean, an agentic feel, a
terminal look — introducing the all-in-one terminal browser, the
valuemaxxing dashboard, and the foreman and crew. The foreman drew it
in Pen over five passes: page-per-section with snapping, a centred
880 px column, more air, a shorter hero, no scroll hint, entrance
animation, then ten taglines, of which the human chose "A terminal
daemon with a ledger." Approved 2026-09-20. The frames live in
`../agent-dashboard/corpus/dashboard.pen` so they share the tokens.

## Next action

The human reviews the PR's preview and merges; Cloudflare Pages
deploys `main`. Then the goal is `done` when the six conditions hold
on kitterm.dev.
