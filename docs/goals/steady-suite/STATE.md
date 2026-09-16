# STATE: steady-suite

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-16, round 1 after: swift test 729 in 82 s, bench p95 2.82 ms, Linux green)
- Updated: 2026-09-16, round 1 closed

## Queue

1. `the-name-never-clips` (capability 2), running now.

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

## Direction

2026-09-16: the human said go on two small items the foreman raised. The
hang has cost three CI or local runs in two days and has sat in
`facts.md` as pre-existing since 2026-09-10 without an owner. The clip
came from the `fleet-catch-up` proposal written the same morning. Both
are one round each and the two are independent.

## Next action

Round 2, `the-name-never-clips`, is running. When it closes and both
branches merge, the goal's four completion conditions can be checked and
the goal closed.
