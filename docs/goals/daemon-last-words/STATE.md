# STATE: daemon-last-words

- Status: done
- Round: 1 of 3 in this budget (third budget)
- Rounds total: 5
- Last floor: green (2026-09-25, round 5 after: swift test 898, KittermCLITests 124, Linux build)
- Updated: 2026-09-25, round 5 closed, done

## Queue

Empty. All three capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

None.

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

None. Round 5 gave `restarted` its writer. Merge the round's PR and
release; an installed daemon records `restarted` only from a new
binary. To reopen, set `Status: active` with a new queue.
