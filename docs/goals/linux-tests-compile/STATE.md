# STATE: linux-tests-compile

- Status: waiting
- Round: 2 of 3 in this budget (first budget)
- Rounds total: 2
- Last floor: green (2026-09-28, round 2 after: swift test 922, the Linux --build-tests pipe green)
- Updated: 2026-09-28, round 2 closed; the ci.yml diff waits on the human

## Queue

1. `ci-compiles-them` (capability 3).

## Failures

None.

## Proposals waiting on the human

- `.github/workflows/ci.yml` (capability 3, Propose tier): the
  `linux-build` job runs `swift build --build-tests`, and its comment
  says it compiles every test target and runs none, because 35 test
  files use `Bundle(for:)`. The exact diff is in `rounds/002.md` and
  the PR description. One green `linux-build` run after the human
  applies it closes the goal.

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

The human applies the `ci.yml` diff on PR #168. Then the foreman
records one green `linux-build` run as capability 3 and sets the goal
done.
