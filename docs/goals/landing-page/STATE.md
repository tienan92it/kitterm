# STATE: landing-page

- Status: active
- Round: 0 of 3 in this budget (second budget)
- Rounds total: 2
- Last floor: green (2026-09-20, round 2 after: html-validate 0 errors, Chromium clean, Lighthouse 95/100/100/100)
- Updated: 2026-09-25, resumed for one round on the human's word

## Queue

1. `the-font-is-first-party`. Serve JetBrains Mono 400 and 600 from
   `site/` with `@font-face` and `font-display: swap`, drop the Google
   Fonts links, and repaint the favicon's old palette (`#161b22`,
   `#30363d`, `#3fb950`) with the dashboard tokens. Proof: Lighthouse
   performance above 95 with accessibility 100, and the HTML and render
   floor.

## Failures

None.

## Proposals waiting on the human

None. The font proposal is queued as round 3.

## Done

- `the-page-moves-as-the-notes-say` (capability 2), round 2, PR #135.
  See `rounds/002.md`. The staggered entrance, the turning marks, the
  blinking cursor, all off under reduced motion; Lighthouse 95/100/100/100.
- `the-page-is-the-frames` (capability 1), round 1, PR #135. See
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

Round 3: `the-font-is-first-party`.
