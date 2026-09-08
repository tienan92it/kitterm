# Plan

The initial floor and the expected capability order for the goal in
`goal.md`. A human owns this file. A foreman proposes a change to it in a
round record; it does not edit it.

## The floor

The floor holds earned behaviour. It starts green and must stay green. A red
floor makes the regression the next round's job.

| Check | Command | Pass condition |
|---|---|---|
| <Unit tests> | `<test command>` | exit 0 |
| <Build> | `<build command>` | exit 0 |
| <Performance check> | `<bench command>` | <metric> under <limit> |

Each round adds at least one deterministic check for the behaviour it
closes. A check that exists is frozen (see `LOOP.md`).

## Capability order

<n> capabilities. Each ships as one PR. Each names the check that proves it.

| # | Capability | Proof |
|---|---|---|
| 1 | **<Name>.** <What ships: the files, the routes, the commands.> | <The test or the corpus request that proves it.> |
| 2 | **<Name>.** <What ships.> | <Proof.> |

<The dependencies between capabilities. Name the independent ones too:
"Capability 2 depends on 1. Capabilities 1 and 3 are independent.">
