# Goal: one rule lives in one place, and the loop enforces it

## Objective

Three documents state the foreman's rules: `docs/goals/LOOP.md` (4,050
words), the skill `examples/foreman/foreman-loop.md` (5,781) and
`docs/foreman.md` (4,467). They already disagree. `LOOP.md` and
`docs/foreman.md` tell the foreman to hold one `wait_for_events`; the
skill tells it to run `kitterm foreman watch` in the background and
yield. The skill's model table names three model ids that no longer
exist. None of the three names `kitterm round open` or `kitterm round
close`. Other rules exist only as prose that a crew can miss: no push
to `main`, no edit under `.github/workflows/`, no second daemon
(`corpus/00-request.md`, changes 3, 6, 7, 8 and 10).

After this goal, each rule has one home. `LOOP.md` holds policy and the
parsed shapes. The skill holds the foreman's procedure. `docs/foreman.md`
holds the reference of the tools and the API. A test fails on a known
stale phrase. A crew session starts with deny rules for the actions
that have no exception. The procedure says what the foreman does on a
stall, before a pull request leaves draft, and before two tasks touch
the same files.

## Exclusions

- No change to the topology: one crew per round, panes, the human merge.
- No automatic merge, and no command that marks a pull request ready.
- No new daemon route.
- No deny rule in a settings file that the foreman's or the human's own
  sessions read. The rules reach crew sessions only.
- No hosted review product. The review before ready is a local session.
- The outcome measures the report defers (a link from a later fix to
  its round, a revert count) stay deferred.

## Charter

The human approved these changes on 2026-11-10 with the words "all
changes" (`corpus/00-request.md`). That approval charters the rounds of
this goal to:

- edit `docs/goals/LOOP.md`, `examples/goals/LOOP.md` (with
  `GoalsTemplates` and its hash history), the skills under
  `examples/foreman/` (with `ForemanSkills`), and `docs/foreman.md`,
  which the Authority table lists as Propose;
- replace an assertion in an existing test that pins a sentence of one
  of those documents, so that it pins the same rule in the rule's one
  home. The rule itself stays; the round record names each old and new
  assertion.

A rule that a round removes, and does not move, is not Chartered: the
crew names it in a `BLOCKER` note and stops.

## Completion condition

All eight hold on the goal's branch:

1. Each of the three documents starts with one paragraph that says what
   the document holds and what the other two hold. `LOOP.md` holds no
   step-by-step foreman procedure, and the skill restates no policy
   table of `LOOP.md`. The three documents together have 11,500 words or
   fewer (14,298 at `8fb3a15`).
2. No rule of the loop is lost. The crew's `DONE` note lists every
   sentence it removed as a duplicate, with the place that keeps the
   rule.
3. A test fails when any of the three documents, or an embedded copy,
   holds a known stale phrase: a held `wait_for_events` as the monitor,
   a model id that `claude --model` refuses, a round step done by hand
   that `kitterm round open` or `kitterm round close` does. The test
   lists its phrases in one table.
4. The procedure opens a round with `kitterm round open` and closes it
   with `kitterm round close`, and tells the foreman to run
   `round close --commit` only after `gh pr checks` is green on the
   head. `LOOP.md` says what the records show about pull requests per
   goal, and "Parsed shapes" states the correction rule of
   `round-commands` round 1.
5. A crew session that the procedure starts runs with deny rules that
   refuse: a push to the base branch, a force push, an edit under
   `.github/workflows/`, an edit to a `goal.md` or a `corpus/` file,
   `gh pr merge`, and `kitterm start`, `stop` and `restart`. A test
   pins the rule file. The crew proves each refusal once in a real
   Claude Code session and gives the refusal text in its `DONE` note.
6. The procedure has one stall rule built on facts: a `completed`
   status with no `DONE` or `BLOCKER` note since the turn began, with
   `screen_state` not `waiting-on-own-job`, is a stall, and the foreman
   answers it within one wake or ends the session. Crew sessions start
   with the setting that continues after a usage limit, or the record
   says with evidence why the setting is not used.
7. The procedure runs one fresh-context review before `gh pr ready`
   (find, then refute, then report the survivors), asks for a `PLAN`
   note approval before code in a round that sets a data model, an
   interface or a visual design, ends a session after two failed
   corrections, and does not start two rounds whose queue items name
   the same files.
8. `swift test` is green, `swift build -c release --product kitterm`
   exits 0, and the pull request's `ci.yml` run is green.
