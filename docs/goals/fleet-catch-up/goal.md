# Goal: the fleet view reads like a terminal, and says each thing once

## Objective

A person opens `/sessions` after hours away and knows within two seconds
what needs them, what broke, and what is still running. The page says
each fact once, in the order a returning reader needs it, and it looks
like the terminal it belongs to: monospace, hairline rules, no pills, no
shadows, no glow, no tinted cards. On a phone the whole state fits in
one or two screens rather than seven. Nothing that the reader cannot act
on is printed.

## Exclusions

- No new information. The page shows less, not more. A number or a line
  that is not on the page today does not arrive through this goal.
- No change to the daemon, the API, or the session model. This is
  `Web/terminal/src/sessions*` and `theme-contrast.test.ts` only.
- No change to what the terminal pane itself looks like. `/` is not this
  goal's surface.
- No new colour pairs unless the contrast ratchet passes them. The ratchet
  can shrink and cannot grow.
- No loss of an accessibility rule an earlier round paid for: the
  `data-focus` key on every control, the live regions, the 44 px tap
  targets, the 390 px single column, and the pure-model split.

## Completion condition

All five hold on a build from `main`:

1. Corpus request `01-back-after-lunch` is satisfied: with its fixture
   loaded, the first screen at 390 px shows every session that needs a
   person, every failed session, and the count of what is still running,
   with nothing above them but the title.
2. No fact appears twice. A session that needs a person appears in the
   strip and not again as a row; a proposal appears once; a goal's slug,
   record link and round counter each appear once or not at all.
3. A session row carries only what a reader acts on: its name, its state,
   what it is doing, and how long. `pid`, `exit 0`, `attached`, the shell
   name, and a path that equals the project root are gone.
4. `sessions.css` contains no `border-radius` above 2 px, no `box-shadow`
   other than a hairline, no `color-mix` tint behind text, and no
   `transition`. A vitest pins each of those four.
5. The floor is green and `main` is green after the merge.

The floor (`tsc --noEmit`, `vite build`, `vitest run`, and the contrast
ratchet inside it) is green at every step.
