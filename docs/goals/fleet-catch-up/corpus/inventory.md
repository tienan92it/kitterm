# Inventory of the fleet view on 2026-09-15

Read-only research done before the goal was planned. Source files:
`Web/terminal/src/sessions.ts`, `sessions-model.ts`, `sessions.css`,
`sessions.html`. The round that added each element is named so a later
round knows what was deliberate.

## Every element, top to bottom

| Element in the code | Shows | When | Added by |
|---|---|---|---|
| `header()` + `.count` | "Sessions" and the total count | always | p&k round 2 |
| `.launch` | "Open a shell" | always | p&k round 2 |
| `pushLine` / `pushToggle` | "Notify this device" switch and its reason line | not watch-only | agent-push round 4 |
| `announce` (`.sr-only`, `aria-live`) | "N items need you" | screen readers only | p&k rounds 2, 5 |
| `strip` (`aria-label="Needs you"`) | the needs-you items | always | p&k round 2 |
| `strip-quiet` | "Nothing needs you." | no items | p&k round 2 |
| strip item `approval` | tool, who, where, waited, `<pre>` args, Open the pane, Allow, Deny | a held tool call | p&k round 2 |
| strip item `needs-input` | headline, place, agent message or `$ command`, Open the pane | a session waits on stdin | p&k round 2 |
| strip item `proposed` | goal title, project, decision line, Open record N, Dismiss | a record's decision starts "propose" | p&k round 6 |
| strip item `failed` | headline, place, detail, Open the pane | last exit non-zero | p&k round 2 |
| `strip-foreman` | "no foreman running" | no `crew: foreman` row | p&k round 2 |
| `pinned` / `foremanRow` | boxed "Foreman" label and one row | a foreman row exists | p&k round 2 |
| `restartLine` (`role="status"`) | the previous run's death, Dismiss | `previous: unrecorded` | dlw rounds 3, 4 |
| `search` | "Search name, folder, or command" | always | p&k round 2 |
| `chips` State / Project / Crew / Made by | filter chips, Clear filters | values present | p&k round 2 |
| `noticeLine` (`role="alert"`) | the last failed action's error | after a failed call | p&k round 2 |
| `card` | project name and full root path | one per project plus "No project" | p&k round 2 |
| `.tallies` | coloured-dot counts per state, or "no live session" | in every card | p&k round 2 |
| `spawnControls` | profile select and "New session" | not watch-only | p&k round 2 |
| `goalSection` expanded | title, slug badge, proposals chip, record link, "round N of M · status · floor X", "next: …" clamped to 3 lines | status active or unknown | p&k round 6 |
| `goalSection` brief | title, status word, proposals chip, record link | waiting, stopped, done | p&k round 6 |
| "no goal folder" | plain text | registered, no goals | p&k round 6 |
| `goal:` / `crew:` sub-headers | the label, "(no folder)" if unmatched | rows carry those labels | p&k rounds 2, 6 |
| `row()` | dot, headline, state, folder tag, profile tag, program tag, `task:` tag, `round N` tag, `$ command` or `shell · cwd`, note, then `attached/detached · held since · N watching · exit N · pid N` | every live session | p&k round 2 |
| `rowActions` | Rename, Archive, Kill; a ⋯ menu under 600 px | not watch-only | p&k rounds 2, 5 |
| `archivedFold` | "Archived (N)" and a list | archives exist | p&k round 2 |
| `.empty` | "No session matches these filters." and two others | no cards | p&k round 2 |

## Where the page says the same thing twice

- `exit N` in the meta line repeats the number `stateLabel` already puts in
  the state word: `failed (1)` and `exit 1` on one row.
- The cwd appears up to three times on a row: as the headline when
  unnamed, as a tag when named, and as `zsh · /path` in the sub line.
  The card header already prints the project root above it.
- A session that needs a person is a strip item and a row.
- A proposal is a strip item and a chip plus a link on the goal card, both
  pointing at the same record.
- The goal slug is a badge on the card and the `goal:` sub-header above
  its rows.
- "round N of M" on the goal card and "round N" as a row tag count
  different things with the same word.
- `pid N` is on every row and nothing on the page acts on a pid.
- `attached` / `detached` is on every row and a phone reader cannot act
  on it.

## What a returning reader needs, ranked

1. What needs me: served by the strip.
2. What broke or was lost: served by the failed items and the restart line.
3. What is still running and where: served by the tallies.
4. What each active goal does next: served but buried under the round
   counter, the floor word, the slug and two links.
5. Whether a foreman is supervising: served by the pinned row.

Serving none of the five: `pid`, `held since`, `N watching`, attached, the
profile tag, the `task:` tag, the card's root path, the slug badge, the
round counter and floor word, the search box, the filter chips, the spawn
controls, the push toggle, the archived fold.

## What is "web app" rather than "terminal" in `sessions.css`

Pills: `.count`, `.launch`, `.chip`, `.push-switch`, `.tag`,
`.spawn-button`, all `border-radius: var(--radius-round)`.
Rounded cards: `.card`, `.card-head`, `.archived`, `.menu.open`,
`.strip-item`, `.restart`, `.notice`, all `var(--radius-2)`.
Shadows and rings: `.count`, `.card-head`, `.tag`, `button.quiet:hover`,
inset `box-shadow`; `.dot` running and attention states carry a 3 px
glow `box-shadow: 0 0 0 3px var(--ui-accent-soft)`.
Tinted backgrounds behind text: `.strip-item` by kind, `.restart`,
`.notice`, `.chip.on`, `.push-switch` on, all `color-mix`.
Animated: `transition: border-color .12s, background .12s` on `.launch`,
`.chip`, `.push-switch`, `.spawn-button`, the approval buttons.

## Rules the redesign must keep, and the round that paid for each

- `data-focus` on every control, restored after every repaint
  (p&k round 5; dlw round 3 reused it).
- The contrast ratchet: pairs derived from the CSS, a new pair under the
  floor fails the build (contrast-tokens rounds 1 and 5; caused by two
  shipped regressions in p&k rounds 5 and 7).
- The pure model in `sessions-model.ts` decides; `sessions.ts` paints
  (p&k round 2, held since).
- Live regions: `announce` polite, `noticeLine` alert, `restartLine`
  status, rebuilt only when the text changes (p&k rounds 5, 7; dlw 3).
- 390 px single column, no horizontal scroll, menus inside the viewport
  (p&k round 2; every round since screenshots it).
- 44 px tap targets, WCAG 2.2 SC 2.5.8 (`sessions.css` names it).
- Time text takes an injected clock, never `Date.now()` (dlw round 4).
