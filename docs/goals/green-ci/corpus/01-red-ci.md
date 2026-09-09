# Request 01: the two failures, reproduced and gone

Approved 2026-09-09. Frozen.

## Fixture

This checkout at the goal's branch, with no artificial load on the
machine. A scratch copy of each test widens the race's window so the
failure is deterministic: for the paced-input test, a reader that takes
longer to apply raw mode; for the takeover test, a first handoff that is
held open. The scratch copies are never committed.

## Request

```
swift test --filter 'PacedInputTests|LiveTakeoverTests'
```
run 20 times in a row.

## Expected behaviour

Before the fix: the widened scratch copy fails every time, with
`PacedInputTests` reporting 409 and `"foregroundProgram":"stty"`, or
`LiveTakeoverTests` reporting statuses other than `[200, 409]`. The
round record names the widening that produced each.

After the fix: the same widening no longer fails, and 20 of 20 runs of
the committed tests pass.

## Expected persistent effects

None beyond the test files. `Sources/` is unchanged: a daemon change to
make a test pass stops the loop.
