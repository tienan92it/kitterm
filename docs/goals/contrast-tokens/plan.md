# Plan

## The floor

The floor of `foreman-harness`, unchanged, plus this goal's own
instrument: the contrast test must fail before a fix and pass after,
theme by theme, so every capability names the themes it moves.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **Measure what the pages use.** Derive the pairs from `sessions.css` and `styles.css`: for each rule that sets a text colour, the surface it sits on. A pair the test cannot resolve fails loudly rather than being skipped. Keep `KNOWN_BELOW` for now, filled with what the derivation finds. | The test enumerates more pairs than the hand list did, and names each; the current failures are the ones the two reviews recorded, plus whatever the derivation adds. |
| 2 | **Raise the mixes.** Change `--ui-text-muted` and `--ui-text-faint` in `tokens.css` so every derived pair passes on every theme, in both polarities. Prefer one rule that holds for all themes over a per-theme table; if a theme needs its own value, say why in the token's comment. | The derived test passes with `KNOWN_BELOW` empty; screenshots of the two worst themes at 1200 px and 390 px, before and after. |
| 3 | **Lower the surfaces.** Change what lifts `--ui-surface`, `--ui-surface-2`, `--ui-hover` and `--ui-active` off `--ui-bg`, and the `.pane-close` opacity at `styles.css:469`, so the pairs the two muted tokens cannot reach clear their floor. The human opened these on 2026-09-11; `rounds/002.md` shows why nothing else can reach them. | The 178 entries over 24 pairs that `rounds/002.md` names are gone from `KNOWN_BELOW`; before and after screenshots on `github-dark` and `solarized-dark`; the ramp still reads text, then muted, then faint, on every theme. |
| 4 | **Make the list a ratchet, and shorten it once more.** Turn `KNOWN_BELOW` from an escape hatch into a ratchet: a pair not already listed that fails the floor fails the build, and a listed pair that starts passing fails the build until its entry goes. Then open the three opacities round 3 left alone, `.settings-gear` at 0.35 and 0.65 and `.keyboard-toggle` at 0.75, which `rounds/003.md` measured as clearing 24 entries. Give every remaining entry the lever that would clear it, or the note that only a theme's own colours could. | A planted new bad pair fails the suite by file, line and selector; a planted entry that now passes fails with "drop this entry"; the 24 opacity entries are gone; every remaining entry carries its blocker. |

Capability 2 depends on 1; capability 3 depends on 2.
