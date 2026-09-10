# STATE: daemon-last-words

- Status: done
- Round: 1 of 3 in this budget (second budget)
- Rounds total: 4
- Last floor: green (2026-09-11, round 4 after)
- Updated: 2026-09-11, done

## Queue

Empty. All three capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

- `plan.md` capability 1: the `restarted` reason still has no writer.
  `kitterm restart` reaches the daemon as the same `SIGTERM` that
  `kitterm stop` sends, so the CLI would have to write its intent before
  signalling. Both are clean ends, so nothing is lost today. See
  `rounds/001.md`.
- `Web/terminal/src/tokens.css`: `--ui-text` is under 4.5:1 on
  `solarized-dark` and `synthwave-84`, and the danger tint the restart
  line paints on takes them lower. This belongs to `contrast-tokens`,
  whose round 3 is running now. See `rounds/003.md`.

## Review, 2026-09-10, before the merge

Two independent reviewers read `goals/say-it-on-the-page`, one on
accessibility and page behaviour, one on reuse and duplication.

Blocking: the date-ambiguous time above.

Cleared, with the evidence read: the Dismiss control carries
`data-focus` through the shared `focusKey` helper and follows the newer
of the two conventions in the file. The line is `role="status"`, a polite
live region, against the top notice's assertive `role="alert"`, and
`paintRestart` only touches the DOM when the text changes, so a restart
is announced once and not on every poll. Dismiss is a real button with
`aria-label="Dismiss the restart notice"`. Tab order matches the visual
order, because `#sessions` does not reorder. Storage is the one shared
guarded pair, parameterised by key, and the in-memory Set is written
first, so a private window hides the line for the page's life instead of
breaking. `mixSrgb` is justified: the two stylesheets really do mix in
sRGB for the tint and in Oklab for the surfaces.

Suggestions, not blocking: `wholeNumber` repeats the parse in `roundOf`,
and the singular-or-plural ternary reaches its third instance here, which
is the repository's own threshold for extracting a helper.

## Next action

None. The goal is done. All four completion conditions hold and every
capability is in `main`:

1. A clean stop records its reason and the next start says so
   (`63c7069`, #85, and `9009fbe`, #88).
2. A `kill -9` leaves no clean reason and the next start names the
   previous pid, when it was last alive, and how many sessions it held
   (`9009fbe`, #88).
3. The fleet view says it once above the cards, dismissible, absent after
   a live upgrade, and it carries the date when the run did not die today
   (`f47a314`, #91).
4. `main` is green: `swift test` 646 tests and vitest 1350 tests, both 0
   failures, plus the Linux build.

To reopen it, set `Status: active`, give it a new budget and a new queue.
Two proposals from its rounds are still open and are listed above.
