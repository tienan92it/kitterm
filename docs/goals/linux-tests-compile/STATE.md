# STATE: linux-tests-compile

- Status: done
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-09-28, round 3 after: swift test 931, the Linux --build-tests pipe green)
- Updated: 2026-09-28, round 3 closed, done

## Queue

Empty. All three capabilities in `plan.md` are done.

## Failures

None.

## Proposals waiting on the human

None. The human applied the `ci.yml` diff on 2026-09-28.

## Done

- `ci-compiles-them` (capability 3), round 3, PR #170. See
  `rounds/003.md`. `linux-build` compiles every test target; its first
  run on `main` caught one unguarded file, fixed here.
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

None. The four completion conditions of `goal.md` hold once PR #170
merges and `main`'s `linux-build` is green. To reopen, set
`Status: active` with a new queue; running the tests on Linux is a new
goal, because 35 files use `Bundle(for:)`.
