# STATE: steady-suite

- Status: done
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-16, round 2 after: swift test 729 in 82 s, vitest 1222, bench p95 2.82 ms, Linux green)
- Updated: 2026-09-16, done

## Queue

Empty. Both capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

- `.github/workflows/ci.yml`: the Linux job runs `swift build` only, so
  it has never compiled `Tests/`, which does not build there at all
  (`MCPSendKeysTests` uses `URLSession` without `FoundationNetworking`).
  Four rounds have said "the Linux build caught a `Sendable` error" and
  every one was a `Sources/` error; a Tests-only one would pass
  unnoticed. Either run `swift test` on Linux, after the import is
  fixed, or say in the workflow that Linux covers `Sources/` alone. One
  round. See `rounds/001.md`.

## Done

- `every-wait-has-a-deadline` (capability 1), round 1, `3a71946`. See
  `rounds/001.md`. One helper, twelve sites, a 30 s deadline measured at
  over 2000x the observed maximum, and a source check that refuses a
  thirteenth bare call.
- `the-name-never-clips` (capability 2), round 2, `8f8e1b7`. See
  `rounds/002.md`. The name no longer shrinks; the count drops first,
  then the select narrows, then it goes. Every real project name reads
  whole at 390 px with a profile selected.

## Direction

2026-09-16: the human said go on two small items the foreman raised. The
hang had cost three CI or local runs in two days and had sat in
`facts.md` as pre-existing since 2026-09-10 without an owner. The clip
came from the `fleet-catch-up` proposal written the same morning. Both
were one round each and the two were independent.

## Next action

None. The goal is done. All four completion conditions hold:

1. No test calls `Process.waitUntilExit()` without a deadline, and a
   source-reading test fails on a bare call by file and line. Proved by
   planting one.
2. A deliberately stalled subprocess fails inside the deadline, at the
   call site, naming the test and carrying what the process last
   printed.
3. At 390 px with the page's own widest profile label selected, every
   registered project's name reads whole: `kitterm`,
   `market-data-pipeline`, `nghenhan-mt5`, `trading-data-api`.
4. `main` is green after both merges.

One proposal stays open, on the Linux job's scope. To reopen, set
`Status: active` with a new budget and queue.
