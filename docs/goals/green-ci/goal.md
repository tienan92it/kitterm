# Goal: CI's test job is green on main

## Objective

The `test` job of `.github/workflows/ci.yml` passes on `main` and on
every branch whose code is sound, so a red check means a real defect. Two
tests fail on the shared macOS runner and pass on a developer machine.
Both assume timing the runner does not give them, and both are fixed by
waiting for the condition each test actually needs.

The two, with the race each one holds:

1. `PacedInputTests.testLargeBodyReachesASlowRawReaderWholeAndInOrder`
   types `stty raw -echo; sleep 2; exec cat -v` and then waits only for
   `!session.foregroundIsShell`. `stty` is itself a program, so the wait
   is satisfied while `stty` runs, before it applies raw mode. The route
   then sees a cooked terminal and answers 409 with
   `"foregroundProgram":"stty"`, which is what CI recorded.
2. `LiveTakeoverTests.testSecondTakeoverWhileOneIsPendingIsRefused`
   fires two `POST /api/upgrade/takeover` requests from a task group and
   asserts the statuses are exactly `[200, 409]`. Two requests started
   together are not two requests in flight together; on a loaded runner
   the first can finish its handoff before the second arrives, and
   nothing then refuses the second.

## Exclusions

- No change to the daemon's behaviour to make a test pass. If a fix
  needs one, it stops the loop and becomes a proposal.
- No retry, no `XCTExpectFailure`, no skip on CI. A test that cannot be
  made deterministic is deleted with its reason in the round record.
- No change to the CI workflow's runner, timeout, or test selection.
- No sweep of other tests; only these two, plus any test the same wait
  helper makes wrong.

## Completion condition

All four hold:

1. Neither test waits on a proxy for its real condition:
   `PacedInputTests` waits until the terminal is in raw mode, or until
   the foreground program is the reader it expects, not merely "not the
   shell"; `LiveTakeoverTests` proves the second request arrives while
   the first is pending, or asserts only what two independent requests
   guarantee.
2. Each test passes 20 consecutive local runs of its own suite, and the
   race it held is reproduced by a widening that the fix then survives.

   Amended by the human on 2026-09-10. This condition first required the
   20 runs "under a parallel load that keeps every core busy". That load
   starved the kitterm daemon on the machine hosting the loop, its
   launchd agent restarted it three times, and two crew sessions died
   with their uncommitted work (`facts.md`, Foreman). Load is also the
   weaker instrument: it makes a race likelier without proving it, and it
   would have accepted a fix that round 1 caught as a proxy. A widening
   that makes the race fail every time, and that the fix then survives,
   is the evidence this goal actually wanted.
3. The full floor is green, and the `test` job is green on the pull
   request that carries the fix.
4. `main`'s next CI run after the merge is green.
