# Plan: one-rule-one-place

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift | `swift test` | exit 0 |
| Release | `swift build -c release --product kitterm` | exit 0 |
| Linux | `swift build --build-tests` in `swift:6.1`, from a tar of `HEAD` | exit 0, when the round adds or edits a test file |
| CI | the pull request's `ci.yml` run | green on the head sha |

The crew runs the first three once after its work. No round touches
`Web/` or the output path, so the web floor and the bench do not run.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **Each rule has one home.** `LOOP.md` keeps policy: roles, goal or chore, the pull request, the floor, authority, the parsed shapes, the budget, direction, the stop rules. The skill keeps the procedure and uses `kitterm round open` and `kitterm round close`. `docs/foreman.md` keeps the set-up, the tools, the typed state and the daemon's behaviour on an upgrade and a restart. A duplicate becomes one sentence that names the home. The stale lines are fixed: the held `wait_for_events`, the three model ids (read the current ids from `claude --help` or the model docs, not from memory), the hand steps the two commands replace, "one pull request per goal", the correction rule. One new test holds the table of stale phrases. | Completion conditions 1 to 4. The `PLAN` note gives the home of each section before the edit. |
| 2 | **Zero-exception rules are deny rules, and a stall is a fact.** A settings file for crew sessions ships under `examples/foreman/`, `kitterm skills install` writes it, and the procedure starts each crew with it (`claude --settings <file>`, or the flag the installed Claude Code documents). The stall rule replaces the present "Stall" section. The crew measures once whether a session that stops on a usage limit sends a hook, if the limit can be met; else the record says it is not measured. | Completion conditions 5 and 6. |
| 3 | **Review before ready; plan before design; no overlap.** The procedure gains the review step (the `review-crew` skill with a refute pass), the `PLAN` approval for a design round, the cap of two failed corrections, and the file-overlap rule in "Schedule". `round close --commit` refuses when `gh pr checks` on the head is not green, with a flag to skip the check for a repository with no CI. | Completion condition 7, and a test for the `--commit` refusal. |

Each round adds one deterministic check for its capability. A round
that sets an interface (round 2's settings file) posts its `PLAN` note
and waits for the foreman's `FOREMAN: approved` before code.
