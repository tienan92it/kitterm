# STATE: linux-tests-compile

- Status: waiting
- Round: 1 of 3 in this budget (first budget)
- Rounds total: 1
- Last floor: green (2026-09-28, round 1 after: swift test 914; the --build-tests pipe red, as measured)
- Updated: 2026-09-28, round 1 closed; a proposal waits

## Queue

1. `the-tests-compile-on-linux` (capability 2).
2. `ci-compiles-them` (capability 3).

## Failures

None.

## Proposals waiting on the human

- `Package.swift`: give `KittermDaemonTests` the `Crypto` product of
  `swift-crypto` on Linux only, so two WebPush test files can import
  `Crypto` where `CryptoKit` is absent, as `Sources/WebPush.swift`
  does. Without it, an unconditional `import CryptoKit` masks the whole
  target on Linux. The alternative is a Linux-only fence around both
  files. Capability 2 waits on this. See `rounds/001.md`.

## Done

- `the-measurement` (capability 1), round 1, no code change. See
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

Waits on the `Package.swift` proposal. On the human's answer, round 2:
`the-tests-compile-on-linux`, clearing the two module-level imports
first, then every error the compiler then shows.
