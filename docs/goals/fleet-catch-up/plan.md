# Plan

The initial floor and the expected capability order for the goal in
`goal.md`. A human owns this file. A foreman proposes a change to it in a
round record; it does not edit it.

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Types | `Web/terminal: ./node_modules/.bin/tsc --noEmit` | exit 0 |
| Build | `Web/terminal: ./node_modules/.bin/vite build` | exit 0 |
| Tests, and the contrast ratchet inside them | `Web/terminal: ./node_modules/.bin/vitest run` | exit 0, 1310 tests at the start |

No Swift changes, so `swift test`, the bench and the Linux build are not
on this goal's floor. A round that finds it must touch `Sources/` stops
and says so.

Each round adds at least one deterministic check for the behaviour it
closes, and every visual claim ships with a screenshot at 1200 px and
390 px on `github-dark`. The corpus fixture in `01-back-after-lunch` is
loaded through the same stub server round 4 of `daemon-last-words` used,
so the screenshots are reproducible without a daemon.

## What the research established

The inventory in `corpus/inventory.md` lists every element the page
renders today, which round added it, and where it repeats itself. The
before-images `corpus/00-before-1200.png` and `00-before-390.png` show the
page on 2026-09-15: 2304 px tall at 1200 wide, 2820 px tall at 390, with
four sessions shown twice, every row carrying `zsh · path · attached ·
exit 0 · pid N`, and two fresh goal templates rendered as raw placeholder
text.

## Capability order

Four capabilities. Each ships as one PR. Each names the check that proves
it.

| # | Capability | Proof |
|---|---|---|
| 1 | **A row is one line.** A session row becomes: dot, name, state, what it is doing, how long. The "what" is the agent's message when there is one, else the last command, else nothing. Drop `pid`, `exit N` when zero, `attached`/`detached`, `N watching`, the shell name, the profile tag, and the path when it equals the project root. Keep the exit code only when it is not zero, and keep it in the state word where `stateLabel` already puts it. | A vitest over the row model asserts the exact field list for an idle shell, a working agent, a failed command, and a named session in a subfolder. The 390 px screenshot of the fixture shows each row on one or two lines. |
| 2 | **Each fact once.** A session in the strip is not repeated as a row; the card shows only the count. A proposal appears in the strip or on the goal card, not both; choose the strip, because that is where a returning reader looks. The goal slug appears once. The record link appears once. The `goal:` and `crew:` sub-headers go, because the row's own tags carry the same words. | A vitest asserts that no session id appears in both the strip model and the card model, and that the proposal model yields one item per proposal. The screenshot shows the four fixture sessions once each. |
| 3 | **Catch-up first, history folded.** The page's order becomes: title, what needs you, what broke, the restart line if any, then projects. Inside a project: running sessions, then active goals as one line each (title · round · next action truncated to one line, no floor word, no slug), then done goals as one folded line "N done", then the archived fold. A goal whose files still hold template placeholders renders as one line "not written yet" rather than the placeholder text. The push toggle, the search box and the filter chips move below the projects, because they are tools rather than status. | Corpus request `01-back-after-lunch` at 390 px: the first screen holds the needs-you and failed items and the running count. A vitest over the goal-card model asserts the placeholder case and the done-fold case. |
| 4 | **The surface is the terminal's.** Remove every `border-radius` above 2 px, every `box-shadow` that is not a 1 px hairline, every `color-mix` tint behind text, every `transition`, and the dot's glow. Cards become sections separated by a hairline; chips become bracketed words; the strip items become lines with a one-character gutter mark. The 44 px tap target stays through padding, not through shape. Every colour pair the ratchet measures still passes or is already listed. | A vitest reads `sessions.css` with `node:fs` (the pattern `theme-contrast-derive.ts` uses) and asserts the four absences. The ratchet is unchanged and green. Before-and-after screenshots on `github-dark` and `solarized-dark` at both widths. |

Capability 1 and 2 are independent. Capability 3 depends on 2, because
it reorders what 2 has de-duplicated. Capability 4 is independent of the
others and can run alongside 1. The human sees the images after 3 and
after 4 before either merges, because both change how the page looks.
