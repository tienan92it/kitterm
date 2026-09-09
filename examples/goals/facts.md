# Facts

Repository facts that a later round must not rediscover: measured
behaviour of the toolchain, the build, the product, and the loop. One
bullet per fact, newest first inside its topic, each with its date and
source in parentheses. A goal-local finding stays in that goal's round
record. A foreman appends; the human prunes at every direction check. A
fact that becomes a rule moves to `LOOP.md`; one that becomes a design
decision moves to `<decision records directory>`.

## Toolchain

- <The package manager, the lockfile, and the command that must not run.
  (<ISO date>, <source: round n, code survey, or session>)>
- <The test command and the platform it runs on. (<ISO date>, <source>)>
- <A flaky check and how to tell a flake from a regression. (<ISO date>,
  <source>)>

## <Topic>

- <One fact: what is true, where it is measured or decided, what it
  costs. (<ISO date>, <source>)>
