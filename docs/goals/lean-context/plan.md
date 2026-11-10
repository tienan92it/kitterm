# Plan: lean-context

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift | `swift test` | exit 0 |
| CI | the pull request's `ci.yml` run (`test`, `linux-build`) | green on the head sha |

The goal changes no file under `Web/` and no file on the output path, so
the web floor and the bench do not run.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **The specification leaves `AGENTS.md`.** Each long section of `AGENTS.md` (the product shape, the binary protocol, the HTTP API, the security model, the control plane, and any other section over 40 lines) moves verbatim to one file under `docs/`, one file per surface. A section that `docs/` already holds in another form, such as `docs/architecture.md`, stays as a separate file; the crew does not merge the two. `AGENTS.md` keeps what an agent cannot read from the code: the build and test commands, the rules that the code does not enforce, the places where the code misleads, and one line per `docs/` file. A test that reads a sentence from `AGENTS.md` reads it from its new file (Chartered). | Completion conditions 1 to 5. The crew's `DONE` note gives the line count, the lost-line count, and the two token numbers. |
| 2 | **`facts.md` drops the facts that later facts reverse.** The foreman's own edit, after capability 1: each reversed fact is deleted, and the fact that replaced it says what it replaced, with its date. The one duplicate pair becomes one fact. | Completion condition 6. The round record lists each fact removed and the fact that replaced it. |

Capability 2 is the foreman's edit to a file the foreman owns, so it
needs no crew round. The human approves it with the merge.
