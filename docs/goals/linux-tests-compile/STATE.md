# STATE: linux-tests-compile

- Status: active
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-28, round 1 after: swift test 914; the --build-tests pipe red, as measured)
- Updated: 2026-09-28, the human answered the proposal: Crypto

## Queue

1. `the-tests-compile-on-linux` (capability 2).
2. `ci-compiles-them` (capability 3).

## Failures

None.

## Proposals waiting on the human

None. 2026-09-28, the human answered "Crypto": round 2 may add
`.product(name: "Crypto", package: "swift-crypto", condition:
.when(platforms: [.linux]))` to the `KittermDaemonTests` dependencies
in `Package.swift`, and nothing else in that file.

## Done

- `the-measurement` (capability 1), round 1, PR #168, no code change. See
  `rounds/001.md`. Two targets compile; `KittermCLITests` has 10
  errors in 2 files; `KittermDaemonTests` is masked by two module-level
  imports, `Darwin` (cleared in the container) and `CryptoKit`.

## Direction

2026-09-28: the human chose this goal from the foreman's plan (the
decision table after v0.33.0). The foreman drafted `goal.md` and
`plan.md`; the status stays `waiting` until the human approves them by
merging this package, then the foreman sets it `active`. The human
merged PR #163 on 2026-09-28.

## Next action

Round 2: `the-tests-compile-on-linux` from `plan.md` row 2; proof: the
`--build-tests` pipe green and `swift test` on macOS at 914 or more.
