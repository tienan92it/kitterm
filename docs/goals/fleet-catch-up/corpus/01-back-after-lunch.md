# Request 01: back after lunch

Approved 2026-09-15. Frozen.

## Fixture

The page state on 2026-09-15 at 16:07, captured in `00-before-1200.png`
and `00-before-390.png` and reproducible through the stub server round 4
of `daemon-last-words` used, with these rows and goals:

- Two sessions in `needs-input`, both named for their folder, both with
  the agent message "Adopt two active Claude sessions finished".
- Two sessions `failed (1)`, one under `market-data-pipeline` and one
  under no project.
- One foreman session, `done`, with a note.
- One idle session under `trading-data-api` in a subfolder,
  `docs/postman`.
- The `kitterm` project with two goals whose files still hold the
  template placeholders, and seven goals with `Status: done`.
- Three other registered projects, two with no goal folder.
- 45 archived sessions under `kitterm` and 4 under no project.

## Request

A person who has been away since lunch opens `/sessions` on a phone,
390 px wide, and reads the first screen without scrolling.

## Expected behaviour

The first screen shows, in this order and nothing else above them:

1. The title.
2. The two sessions that need input, each on one or two lines: name,
   the agent's message, how long they have waited.
3. The two failed sessions, each on one line: name, the exit code, how
   long ago.
4. One line saying how many sessions are running and how many are idle.

Scrolling down, each project is a section under a hairline, holding its
running sessions once each, its two unwritten goals as two lines reading
"not written yet", and its seven done goals as one folded line "7 done".
The four needs-input and failed sessions do not appear again as rows.

No row anywhere on the page prints `pid`, `attached`, `zsh`, `exit 0`,
or a path that is the project's own root.

## Expected persistent effects

None. The page reads state and changes nothing.

## What passes

The 390 px screenshot of the fixture, with the first screen matching
items 1 to 4, and the vitest cases capability 1 to 3 name in `plan.md`.
