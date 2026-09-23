# Goal: one rule lives in one file

## Objective

A person who changes a rule of the loop edits one file. Today a rule
lives in five: `docs/goals/LOOP.md`, `examples/goals/LOOP.md`, the
foreman skill, and the two Swift strings that embed the last two. The
2026-09-21 rule change cost two crew sessions and a test to hold the
copies equal.

After this goal, `LOOP.md` holds the contract a crew must keep, the
skill holds the procedure a foreman drives kitterm with, and neither
restates the other. `facts.md` is unchanged; it has no copy anywhere.

## Exclusions

- No rule is added, removed or reworded. This goal moves text and
  cuts duplication; a sentence that changes meaning is a defect.
- The two template mirrors stay: every project owns a copy of
  `LOOP.md`, and the binary embeds it so `kitterm goal new` needs no
  resource bundle.
- No change to any goal's own package under `docs/goals/<slug>/`, and
  none to another project's `LOOP.md`.
- No change to `kitterm project init --refresh`; the hash list grows
  by one entry as it does for any template change.

## The four tiers

Every rule of the loop sits in exactly one tier, and its tier decides
its file.

| Tier | What it is | Breaking it | Lives in |
|---|---|---|---|
| 1 · parsed | a shape the daemon reads: `- Status:`, `- Round: N of M`, `## Next action`, `## Queue`/`## Done`/`## Failures`, `PR #N`, `- Cost:`, `- Started:`, the five labels | the product misreads the package | `LOOP.md`, one section, each with the route that reads it |
| 2 · hard | the authority tiers, the budget, one crew per round, the cap of three, commit after every round | the round fails or the package corrupts | `LOOP.md` |
| 3 · procedure | read the screen before typing, the trust dialog, the epoch respawn, how to wait | time is wasted, work is not | the skill |
| 4 · guidance | the model per task, when to notify, how to word a prompt, the three notes | nothing; the foreman judges | the skill, marked as guidance |

## Completion condition

All six hold on a build from `main`:

1. `LOOP.md` holds tiers 1 and 2 and nothing of tiers 3 and 4; its
   `Parsed shapes` section names every parsed shape with the route or
   the parser that reads it.
2. The skill holds tiers 3 and 4 and, for the contract, one sentence
   that sends the reader to `<knowledge>/LOOP.md`.
3. No section heading appears in both files. Today thirteen do.
4. `GoalsLayoutDocsTests` pins the parsed shapes across the five
   copies and nothing else; every rule sentence it pins today either
   moved to that section or is named in the round record as dropped.
5. `swift test` and the Linux build are green, and `kitterm goal new`
   on a scratch directory writes a package a crew can read.
6. Every sentence in the new files appears in the old ones, or the
   round record names it and why.

The floor (`swift test`, the Linux docker pipe, `swift test --filter
KittermCLITests`) is green at every step.
