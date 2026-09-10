# STATE: daemon-last-words

- Status: waiting
- Round: 3 of 3 in this budget (first budget spent: rounds 1, 2, 3)
- Rounds total: 3
- Last floor: green (2026-09-10, round 3 after)
- Updated: 2026-09-10, budget spent and review returned

## Queue

Empty. All three capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

- **The merge is blocked by one review finding.** `sessions.ts` prints the
  previous run's time with `clockTime`, which renders only the hour and
  the minute. The daemon can be down overnight or over a weekend, so
  "last alive at 10:35 PM" with no date is wrong for any run that did not
  die today. The same file already has the right convention for a stamp
  that can be old: `archivedFold` uses `toLocaleString()`, which carries
  the date. The fix is one formatter and its cases. The budget is spent,
  so this needs the human to say continue before round 4 runs.

- `plan.md` capability 1: the `restarted` reason has no writer. `kitterm
  restart` reaches the daemon as the same `SIGTERM` that `kitterm stop`
  sends, so the CLI would have to write its intent before signalling.
  Both are clean ends, so nothing is lost today. See `rounds/001.md`.
- `Web/terminal/src/tokens.css`: `--ui-text` is under 4.5:1 on
  `solarized-dark` and `synthwave-84`, and the new 8% danger tint takes
  them to 3.85 and 3.30. The fix belongs to `contrast-tokens`, which is
  running now. See `rounds/003.md`.

## Done

- `record-how-a-run-ends` (capability 1), round 1, `f76ec7c`. See
  `rounds/001.md`.
- `report-the-previous-run` (capability 2), round 2, `884be00`. See
  `rounds/002.md`.
- `say-it-on-the-page` (capability 3), round 3, `39127a2`. See
  `rounds/003.md`.

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

Waiting on the human. The budget is spent and the review returned one
blocking finding, so the goal needs a direction check.

On continue: round 4 is one formatter. Replace `clockTime` in the restart
line with a formatter that carries the date when the previous run did not
die today, and add the cases to `sessions-model.test.ts`. Then merge
`goals/say-it-on-the-page` and check `main` green, which is completion
condition 4. Capabilities 1 and 2 are already in `main` as `63c7069`
(#85) and `9009fbe` (#88), so capability 3 is the last one. Set
`Status: done` after `main` is green.

One merge order to keep: `goals/derive-the-pairs-work` rewrites
`theme-contrast.test.ts` whole, and this branch adds one hand-written row
to the old shape of that file. Merge the contrast branch first. The
derivation finds that row's pair by itself, so the rebase deletes the
hand-written row rather than moving it.

One collision to watch: `contrast-tokens` is rewriting how
`theme-contrast.test.ts` derives its pairs, and round 3 added a `tint`
row to that same file. Whichever merges second rebases.
