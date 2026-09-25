# STATE: daemon-last-words

- Status: active
- Round: 0 of 3 in this budget (third budget)
- Rounds total: 4
- Last floor: green (2026-09-11, round 4 after)
- Updated: 2026-09-25, resumed for one round on the human's word

## Queue

1. `restart-says-restarted` (capability 1). `kitterm restart`, with or
   without the service, records `reason: restarted` in
   `~/.kitterm/last-run.json`: the CLI writes its intent before it
   signals, and the daemon's stop reads it. `kitterm stop` still records
   `stopped`. The vocabulary stays as it is.

## Failures

None.

## Proposals waiting on the human

None. The `restarted` proposal is queued as round 5: the CLI writes its
intent, so the vocabulary keeps `restarted`.

2026-09-25, the foreman closed the `tokens.css` item: the restart line
paints the danger tint on its mark alone now, and `contrast-tokens` is
done.

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

Round 5: `restart-says-restarted`.
