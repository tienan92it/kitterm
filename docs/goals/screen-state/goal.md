# Goal: the foreman knows what a pane shows from one tool call

## Objective

A foreman calls one MCP tool, `screen_state {session}`, and learns
what a crew pane shows: an empty prompt, a prompt with text, a running
turn, a crew that waits on its own background job, a trust dialog, a
permission dialog, an exited agent, or `unknown`. Rules over the
rendered screen decide it, with the rule that matched and the line it
matched, with no network call. The tool counts its answers, so the
human can see how often the rules say `unknown`. When the human turns
it on, an opt-in Clef-flash fallback answers an `unknown` screen with a
state and its probability, marked as Clef's. The foreman skill calls the
tool first and reads the screen only when it must.

## Exclusions

- The daemon does not judge a screen and gains no route for it.
- No push notification is filtered by the state (issue #171, open
  question 1).
- No dialog answer and no permission decision is ever taken from a Clef
  answer.
- No screen text leaves the machine unless the human wrote the Clef
  configuration.
- No local model: the Clef weights need a CUDA GPU.

## Completion condition

All 6 hold on a build from `main`:

1. `screen_state` answers each of the eight states of issue #171 for a
   recorded screen of that state, with `rule` and `line`, and `unknown`
   for a screen with no marker; a test per recorded fixture.
2. The fixtures are real screens of Claude Code, recorded from a scratch
   pane in each state, with the Claude Code version that made them.
3. The bridge appends one line per answer to a bounded local log, and
   `kitterm screen-state stats` prints the count per state and the share
   of `unknown` over a window.
4. With no Clef configuration, the tool makes no network call (a test
   proves it); with one, an `unknown` screen goes to Clef-flash, and the
   answer carries `source: "clef"`, the probability, and `unknown` when
   the top probability is under the configured threshold.
5. The Clef token is read from a file the human names, is never logged,
   and a missing or unreadable token gives `unknown` with a reason.
6. The foreman skill's "Read before you type" calls `screen_state`
   first, reads the screen on `unknown` and on a Clef answer before it
   types, and both skill copies say so.

The floor (Linux build, `swift test`, the web checks unchanged) is green
at every step.
