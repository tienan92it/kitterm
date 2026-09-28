# STATE: linux-tests-compile

- Status: active
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-28, round 2 after: swift test 922, the Linux --build-tests pipe green)
- Updated: 2026-09-28, the human applied the ci.yml diff; main's first run is red

## Queue

1. `ci-compiles-them` (capability 3). The human applied the diff in
   PR #168. The first `linux-build` on `main` with `--build-tests`
   (run 36401242263, `e6ea063`) is red: `CommandFailedEventTests.swift`,
   merged in PR #169 after PR #168, uses `URLSession` with no
   `FoundationNetworking` import (4 errors). Guard it, then one green
   run on `main` closes the goal.

## Failures

None.

## Proposals waiting on the human

None. The human applied the `ci.yml` diff on 2026-09-28.

## Done

- `the-tests-compile-on-linux` (capability 2), round 2, PR #168. See
  `rounds/002.md`. All four test targets compile on Linux; macOS still
  runs 922 tests; two named Linux-only fences.
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

Round 3: `ci-compiles-them`, the import guard, then one green `linux-build` on `main`.
