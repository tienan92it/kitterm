# Goal: the suite always finishes, and the page never clips a name

## Objective

`swift test` either passes or fails, and never hangs. Every test that
waits on a subprocess waits with a deadline, and a deadline that expires
fails that test by name with what the process last printed, so a reader
knows which daemon stalled and why. On the fleet view, a project's name
is never the thing that clips: at 390 px with a real profile selected,
the name reads in full and the controls beside it give way.

## Exclusions

- No change to what any test asserts. A test that passes today passes
  after this, with the same assertions; only its waiting changes.
- No fix for the underlying Foundation behaviour. The deadline makes the
  hang a failure with a name; it does not make the subprocess exit.
- No new dependency, and no change to `Package.swift`.
- No redesign of the card heading beyond what stops the clip. The
  heading stays one line.
- No change to the daemon, the API or the session model.

## Completion condition

All four hold on a build from `main`:

1. No test calls `Process.waitUntilExit()` without a deadline. A check
   reads the test sources and fails on a bare call, naming the file and
   the line.
2. A deliberately stalled subprocess fails its test inside the deadline,
   and the failure names the test and carries the process's last output.
   Proved by a test that stalls one on purpose.
3. At 390 px with the longest bundled profile name selected, a project
   card's heading shows the project's name in full; the profile control
   and the count give way first. Proved by a vitest over the model and a
   screenshot of the live page.
4. The floor is green and `main` is green after the merge.

The floor (`swift test`, the web suite, `KittermBench interactive-echo`
under 50 ms p95, and the Linux build) is green at every step.
