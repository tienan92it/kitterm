# Goal: a crew starts with a small context

## Objective

Claude Code reads `AGENTS.md` at session start when the repository has
no `CLAUDE.md`, and kitterm has none. Every crew session therefore loads
the whole file, 178 KB and about 55k–62k tokens (estimated), and reads it
again from the cache on every request. Six crew sessions measured a
first request of 111k–124k tokens, against 48k–51k in a repository with a
small `AGENTS.md` (`corpus/01-research-report.md`, change 1). A
controlled study found that such a file adds about 20% cost and no
significant success.

After this goal, `AGENTS.md` holds only what an agent cannot read from
the code, in 200 lines or fewer. The product specification it holds
today lives under `docs/`, one file per surface, with its content
unchanged, and `AGENTS.md` names each file. `facts.md` holds no fact that
a later fact reverses (change 9).

## Exclusions

- No product code changes.
- The specification moves verbatim. Rewording, wrapping, and removing
  the duplicates inside it are later work.
- No `CLAUDE.md`. One instruction file serves Claude Code and every
  other agent that reads `AGENTS.md`.
- No `.claude/rules/` files. Add path-scoped rules later, when a
  measured round shows that a crew missed a rule the short file dropped.
- `LOOP.md`, the foreman skill, and `docs/foreman.md` belong to the goal
  `one-rule-one-place` (`corpus/00-request.md`).

## Charter

The human approved this change on 2026-11-10 with the words "all
changes" (`corpus/00-request.md`). That approval charters the rounds of
this goal to replace an assertion in an existing test that reads a
sentence from `AGENTS.md`, so that the assertion reads the same sentence
from the `docs/` file it moved to.

## Completion condition

All six hold on the goal's branch:

1. `wc -l AGENTS.md` prints 200 or less, and no line of `AGENTS.md` is
   longer than 500 characters.
2. Every non-blank line of `AGENTS.md` at `d3a7711` that is longer than
   40 characters is in the new `AGENTS.md` or in a file under `docs/`. A
   script the crew runs prints the count of lost lines, and the count is
   0.
3. `AGENTS.md` names each new `docs/` file on one line with what it
   holds, and says that a round which changes a surface updates that
   surface's file.
4. `claude -p --output-format json 'Reply with the word ok.'` in the
   repository root uses 70k input tokens or less on its first request
   (input plus cache creation plus cache read). The same command at
   `d3a7711` gives the baseline. Both numbers are in the crew's `DONE`
   note.
5. `swift test` is green, and the pull request's `ci.yml` run is green.
6. `facts.md` holds no pair of facts where the later one reverses the
   earlier one without a marker, and no duplicate pair.
