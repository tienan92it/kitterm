# Request 01: the two failures, reproduced and gone

Approved 2026-09-09. Frozen.

## Fixture

This checkout at the goal's branch, on a machine where every core is
busy: run `for i in $(seq 8); do yes > /dev/null & done` before the
measurement and kill the load after.

## Request

```
swift test --filter 'PacedInputTests|LiveTakeoverTests'
```
run 20 times in a row under that load.

## Expected behaviour

Before the fix: at least one run of the 20 fails, with
`PacedInputTests` reporting 409 and `"foregroundProgram":"stty"`, or
`LiveTakeoverTests` reporting statuses other than `[200, 409]`. The
round record names which failed and how often.

After the fix: 20 of 20 runs pass, and the failure cannot be produced by
adding load.

## Expected persistent effects

None beyond the test files. `Sources/` is unchanged: a daemon change to
make a test pass stops the loop.
