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
| 3 | **Delete the escape hatch.** Remove `KNOWN_BELOW` and its plumbing, so a failing pair is a failing test with no way to record it as expected. | The mechanism is gone; a planted bad pair fails the suite. |

Capability 2 depends on 1; capability 3 depends on 2.
