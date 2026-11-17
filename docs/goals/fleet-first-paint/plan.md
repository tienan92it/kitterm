# Plan: fleet-first-paint

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift | `swift test` | exit 0 |
| Web tests | `pnpm test` in `Web/terminal` | exit 0 |
| Web build | `pnpm build` in `Web/terminal`, with `--outDir` outside the main checkout | exit 0 |
| Release | `swift build -c release --product kitterm` | exit 0, when the round changes a file under `Sources/` |
| Bench | `KittermBench` against a scratch daemon on its own port | `RESULT: PASS`, when the round changes a file under `Sources/KittermDaemon/` |
| CI | the pull request's `ci.yml` run | green on the head sha |

The crew runs its own checks once after its work. `ci.yml` proves the
Swift tests, the release build and the Linux build on the pull request;
the crew does not run the Linux build. `facts.md` gives the scratch
daemon and the web install for a fresh worktree.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **`paint-first`: the page paints the fleet, then fills.** `poll()` in `Web/terminal/src/sessions.ts` renders after `sessions`, `projects`, `approvals` and `limits`. The archives, the usage with the yield, the bills and the lifetime each load outside that wait and repaint their own section. Each section has a waiting state. The page asks for the archives once after the paint, then when an archive event arrives or the fold opens. | Completion conditions 1 and 2, and the page half of 4. The `PLAN` note names the waiting state of each section before the crew writes code. |
| 2 | **`yield-never-waits`: the yield routes answer from what is kept.** `RepositoryYields` answers what it holds and starts one refresh on `kitterm.yield` when the answer is old or absent, as `PullRequestStatus` does for `gh`. The answers are kept on disk under the state directory. The body says when a read is pending and how old the answer is. The page shows the pending state and asks again. | Completion condition 3. The `PLAN` note gives the body's new fields and the file on disk before the crew writes code. |
| 3 | **`archives-cheap`: the archive list costs bytes only on a change.** `GET /api/archives` gets an `ETag` and 304. The daemon keeps the list in memory and reads the directory again only after an archive is written or removed. The page sends `If-None-Match`. One check holds the first-paint budget with 600 archives. | Completion conditions 4, 5 and 6. |

Capability 2 and capability 3 are independent of each other. Both follow
capability 1, because all three edit `sessions.ts`.

Each round adds one deterministic check for its capability. Rounds 1 and
2 set a visual state or an interface: the crew posts its `PLAN` note and
waits for `FOREMAN: approved` before code. A round that changes a route
updates `docs/http-api.md` in the same round.
