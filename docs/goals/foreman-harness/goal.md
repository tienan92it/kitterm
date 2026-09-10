# Goal: the foreman's own tools stop lying to it

## Objective

Three things the loop uses every round are wrong in a way that costs a
round, not a minute. Each was found by running the loop, and each is
recorded in a round record of a finished goal.

1. **A foreman cannot press a key.** The MCP bridge drops the escape byte
   from `send_input`, so an escape sequence for the Down arrow reaches a
   pane as the two bytes `[B`. Answering a folder-trust dialog, the one
   keystroke the skill tells a foreman to send, is impossible through the
   toolset. The installed skill now carries a `printf` and `curl`
   workaround against the HTTP route, which is the only place it tells a
   foreman to bypass its own tools.
2. **A registered parent swallows a nested checkout.** Project resolution
   takes the longest registered root before it walks for `.git`, so
   registering a folder hides every repository under it. Round 2 of
   `projects-and-knowledge` lost its fixture to this.
3. **Four rules of the loop are unwritten or wrong.** A round attempt the
   host machine kills spends the budget; a test that pins a layout
   `goal.md` replaces counts as Frozen and stops a round; `resumed-from`
   is documented as an archive id although a respawn after an epoch
   change has no archive; and the note goes out after the floor, so a
   session that dies at its last step leaves no evidence.

## Exclusions

- No new MCP tool. The key fix extends `send_input` or adds one argument
  to it.
- No change to the input route's byte contract: the daemon already
  carries control bytes; the bridge is what drops them.
- No rewrite of the procedure in `LOOP.md`. The four rules are additions
  and corrections, not a new loop.
- No retrospective edit of a finished goal's `plan.md`. Two rows there
  name stale counts; they are history, and the record beside them is
  right.

## Completion condition

All five hold:

1. A foreman sends an arrow key through the MCP toolset alone, and a test
   proves the three bytes reach the pane.
2. `examples/foreman/foreman-loop.md` answers the trust dialog with the
   toolset, with no `curl` in its text, and `kitterm skills install`
   carries it.
3. A session whose cwd is a git checkout under a registered parent
   resolves to the checkout, and the resolution table test pins it.
4. `docs/goals/LOOP.md`, `examples/goals/LOOP.md`, and the skill carry
   the four rules and agree with each other.
5. The floor is green and `main` is green after the merge.
