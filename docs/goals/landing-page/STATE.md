# STATE: landing-page

- Status: done
- Round: 1 of 3 in this budget (second budget)
- Rounds total: 3
- Last floor: green (2026-09-25, round 3 after: html-validate 0 errors, Chromium clean, Lighthouse 100/100/100/100)
- Updated: 2026-09-25, round 3 closed, done

## Queue

Empty.

## Failures

None.

## Proposals waiting on the human

None.

## Done

- `the-font-is-first-party`, round 3, PR #158. See `rounds/003.md`.
  JetBrains Mono is served from `site/fonts/`; Lighthouse performance 95
  to 100; the favicon wears the dashboard tokens.
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

None. Merge the round's PR; Cloudflare Pages then serves the fonts from
kitterm.dev. To reopen: set `Status: active` and write a queue.
