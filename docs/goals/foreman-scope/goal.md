# Goal: each foreman keeps its own projects, and a new one catches up

## Objective

Today the skill says one foreman serves every project on a daemon, while
the human runs one foreman per workspace; the scope rule lives only in one
foreman's memory, and that gap once made a foreman end another's session
(`corpus/01-two-handovers.md`). A project's `LOOP.md` changes only when the
human copies a new template in, or when `kitterm project init --refresh`
finds an unedited copy. A new foreman rebuilds its picture of the work by
hand, and can miss what the human told its predecessor.

After this goal, a foreman knows its scope, acts inside it only, keeps the
goal packages of its projects current through PRs the human merges, and
starts by catching up on its predecessor's work in the same scope with one
command.

## Exclusions

- The foreman still does not merge; the human merges every PR.
- No change to what the daemon judges: the scope is a label and a cwd, read
  by the skill and the CLI.
- No automatic edit of a project's `LOOP.md`: an edited file changes only
  through a PR the human merges.
- The NgheNhanTrading projects are not changed by this goal. Their foreman
  uses the new skill and command after the release.

## Charter

The human approves this package by merging it. That approval charters its
rounds to edit the foreman skill with its embedded copy, the goal template
`examples/goals/LOOP.md` with its embedded copy, `docs/foreman.md`, and, in
kitterm's own `docs/goals/LOOP.md`, the Roles bullet on the foreman, the
Labels table, and the section "One foreman for every project".

## Completion condition

All five hold on a build from `main`:

1. The skill and `LOOP.md` say that a foreman's scope is the projects whose
   root lies under its scope directory: the value of its `scope:<path>`
   label, else its pane's cwd. A foreman acts only on projects in its scope,
   and "one foreman per daemon" becomes "one foreman per scope".
2. `kitterm project init --refresh --check <root>` prints `current`,
   `behind` (an unedited copy of an older template) or `edited`, writes
   nothing, and exits 0 for each; a test pins all three.
3. The skill's upkeep step: after a skills update, the foreman runs the
   check for every project in its scope, refreshes a `behind` one in a chore
   PR, and opens a draft PR that merges the new template sections into an
   `edited` one while keeping the project's own lines.
4. `kitterm foreman catch-up [--scope <path>]` prints, for one scope: the
   predecessor (the newest live or archived session labelled
   `crew:foreman…` in that scope) with its note and the last assistant
   message of its transcript; each project's goals that are not done, with
   status, round and next action; the live labelled crew sessions; and the
   worktrees under `.claude/worktrees/`. It prints nothing from outside the
   scope. A test over a fixture state directory pins it.
5. The skill's start step runs the catch-up before anything else, and a
   foreman started in a pane whose scope already has a live foreman stops
   and tells the human.

The floor (`swift test`, the PR's `ci.yml` run) is green at every step.
