# LOOP

The procedure, the authority, the budget, and the stop rules for every goal
loop in this repository. This file changes when the process changes.
`STATE.md` changes after every round.

The repository is the control plane. This package is small on purpose:
`goal.md`, `facts.md`, `plan.md`, `LOOP.md`, `STATE.md`, `corpus/`,
`rounds/`. Add a file only when a round proves the package cannot hold a
fact without it.

## Roles

- **The human** owns rounds. The human writes `goal.md`, `plan.md`, this
  file, and `corpus/`. After each budget the human picks continue,
  redirect, or stop.
- **The foreman** owns turns inside a round. The foreman is an agent in a
  kitterm pane that runs the `goal-loop` skill on the kitterm MCP tools. It
  writes `STATE.md`, `rounds/`, and appends to `facts.md`. It never answers
  a permission dialog for a crew agent.
- **A crew agent** runs in a session the foreman spawned. It changes the
  product and adds checks. It reports with `post_note`.

## Authority

| Tier | Paths | Rule |
|---|---|---|
| Free | `Sources/`, `Web/terminal/src/`, `Tests/` new files, `docs/*.md` except this package, `AGENTS.md`, `examples/`, `STATE.md`, `rounds/`, `facts.md` (append) | The crew and the foreman change these inside a round. |
| Propose | `plan.md`, this file, `docs/adr/`, `.github/workflows/`, `Package.swift`, `Web/terminal/package.json`, `Bench/` | The foreman writes the proposal in the round record with decision `propose`. The human edits the file. |
| Frozen | `goal.md`, `corpus/`, an existing test file, an existing bench scenario and its gate, `Web/terminal/pnpm-lock.yaml` | Nobody changes these inside a round. A repair that needs one stops the loop. |

Before the foreman accepts a round it runs `git diff --name-only <base>` in
the crew session and reads the output. A path under Frozen fails the round.
A path under Propose turns the round's decision into `propose`. A deleted or
weakened assertion in an existing test counts as a Frozen change.

The loop can change the product. It cannot change the evidence that decides
whether the product improved.

## Budget

- Three rounds per direction check. `STATE.md` counts them.
- One correction per round. A second failure ends the round as failed.
- One crew session per round, plus review sessions when the round's
  capability touches `Sources/KittermDaemon/PtySession.swift` or
  `HTTPAPIHandler.swift`.

## One round

1. **Read.** Read `goal.md`, `facts.md`, `plan.md`, `STATE.md`, and the
   decisions `STATE.md` cites. Take the head of the queue. Stop when the
   budget is spent.
2. **Verify the world.** Spawn one crew session in the repository root with
   labels `crew:<goal>`, `goal:<slug>`, `round:<n>`, `task:<queue-item>`,
   and `input:"claude\n"`. Read the screen. Run the floor from `plan.md`. A
   red floor makes the regression this round's job and pushes the queue item
   back.
3. **Send one request.** Type the round prompt in one `send_input`: the
   queue item, its proof from `plan.md`, the facts that apply, the frozen
   and propose paths, the corpus request it serves, and the rule to add a
   deterministic check. From here the foreman loop applies: read before you
   type, wait on `wait_for_events`, route `needs-input` and `needs-approval`
   to the human, never answer for them.
4. **Collect.** On `completed`, read the last command output and the screen.
   Run the floor again. Read the diff. Collect the visible proof the crew
   posted with `post_note`: a screenshot path, a test name, a URL.
5. **Classify the largest gap.** One class per round:
   - **world**: the environment, the daemon build, the toolchain.
   - **domain**: the product's own logic.
   - **contract**: an interface between two layers (route, protocol, type).
   - **runtime**: a crash, a timeout, a resource limit.
   - **steering**: the prompt or the plan misled the crew.
   - **surface**: the effect happened; the proof is not visible.
   - **harness**: the loop's own tools, skills, or this file.
   Write the class and its evidence in the round record. A round with no
   gap records `none`.
6. **Close or record.** Floor green and the diff holds the check: mark the
   item done, archive the crew session, record the archive id. Otherwise
   record the gap, send one correction, and count it inside this round.
7. **Reflect.** Answer one question in the record: what cost time that a
   rule or a check could prevent? Append a fact to `facts.md`. Propose a
   rule change to this file when the answer is a procedure.
8. **Update `STATE.md`.** Queue, failures, next action, round counter,
   budget left.

## Stop rules

The foreman stops and tells the human when:

- the budget is spent;
- a repair needs a change under Frozen;
- the floor is red at the start of two rounds in a row;
- a failure does not reproduce in a fresh session;
- the crew session reports `exited` with a non-zero code twice;
- the daemon `epoch` changes and the crew is gone (respawn once, then stop).

## Round record

Write `rounds/NNN.md` with this shape. Three-digit number, one file per
round, never rewritten after the round ends.

```markdown
# Round NNN: <queue item>

- Goal: <slug>
- Started: <ISO date>  Ended: <ISO date>
- Sessions: <id>, <id>   Archives: <id>
- Base: <git sha>   Result: <git sha or PR #>

## Prompt
<the request sent, verbatim or a path to it>

## Floor
before: green | red (<check>)   after: green | red (<check>)

## Effects
- behaviour: <what the crew did>
- visible: <screenshot path, test name, URL>
- persistent: <files, state, records>

## Gap
class: world | domain | contract | runtime | steering | surface | harness | none
evidence: <one line>

## Decision
done | failed | propose (<path>: <what and why>)

## Reflection
<what cost time that a rule or a check could prevent>
```

## Labels

| Key | Value | Set by |
|---|---|---|
| `crew` | goal slug | foreman |
| `goal` | goal slug | foreman |
| `round` | round number | foreman |
| `task` | queue item slug | foreman |
| `resumed-from` | archive id | foreman, on a respawn |
