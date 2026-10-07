# Plan

The initial floor and the expected capability order for the goal in
`goal.md`. A human owns this file. A foreman proposes a change to it in a
round record; it does not edit it.

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Linux build | the `facts.md` docker pipe with `swift build --build-tests`; the PR's `linux-build` check proves it | `Build complete`, 0 errors |
| Swift tests | `swift test`, once by the crew; the PR's `test` check proves it again | exit 0 |

No web change and no output path change, so no web floor and no bench.
Each round adds at least one deterministic check for the behaviour it
closes. A check that exists is frozen (see `LOOP.md`).

## Capability order

4 capabilities. They ship on one branch, `goal/screen-state`, and one
pull request.

| # | Capability | Proof |
|---|---|---|
| 1 | **The fixtures.** Drive `claude` in scratch panes (labelled `crew:helper`) into each state of issue #171, and save each rendered screen (`read_screen`'s answer) as a fixture under `Tests/KittermCLITests/Fixtures/screen-state/`, with the state, the Claude Code version and the date. A permission dialog is recorded and never answered. | The fixtures, one or more per state, and a test that every fixture parses. |
| 2 | **The rules and the tool.** `ScreenState` in `KittermCLI`: pure rules over a rendered screen, answering `{state, rule, line}`; the MCP tool `screen_state {session}` reads the screen as `read_screen` does and answers the rules' state. | One test per fixture; a screen with no marker is `unknown`; `MCPToolsTests`' tool count is Chartered by this row. |
| 3 | **The count and the skill.** One JSON line per answer to `~/.kitterm/screen-state.log` (0600, bounded, `KITTERM_STATE_DIR` moves it); `kitterm screen-state stats [--days N]`; "Read before you type" in both skill copies calls the tool first. | Tests for the log bound, the stats output, and the skill's text. |
| 4 | **The opt-in Clef fallback.** `~/.kitterm/clef.json` (`{accountId, tokenFile, model, threshold}`) turns it on; an `unknown` screen goes to Workers AI with one `choice` question over the states; the answer is `{state, source: "clef", probability}`, or `unknown` under the threshold or on any error, with a reason. | Tests with a fake HTTP endpoint: no call with no configuration, the request shape, the threshold, each error, and the token never in a log or an answer. |

Capability 2 depends on 1, 3 on 2, 4 on 2. Three rounds run before the
direction check; capability 4 runs after it, and the human decides it
there with the count from capability 3.
