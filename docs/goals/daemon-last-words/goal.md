# Goal: the daemon says why it died

## Objective

On 2026-09-09 the daemon died three times and wrote nothing. Each death
took every session, and with them two crew sessions' uncommitted work.
The cause was found from `launchctl print` and `sysctl vm.swapusage`,
not from the product: `server.log` held only "kitterm daemon listening"
lines, and the fleet view showed new session ids with no explanation.

A human, and a foreman, must be able to tell these three apart without
leaving kitterm:

- the daemon stopped on purpose (`kitterm stop`, `kitterm restart`);
- the daemon replaced itself in place (`kitterm upgrade --live`), which
  keeps every session;
- the daemon died and something restarted it, which loses every session.

## Exclusions

- No attempt to survive the kill. A process the kernel kills cannot save
  itself; this goal is about what the next process can say.
- No crash reporter, no symbolication, no third-party service.
- No change to the takeover handoff, which already carries its own state.
- No metrics endpoint and no health history beyond the last run.

## Completion condition

All four hold:

1. A clean stop records its reason, and the next start says the previous
   run ended cleanly.
2. A `kill -9` of the daemon leaves no clean reason, and the next start
   says so, naming the previous pid, the time it was last alive, and how
   many sessions it held.
3. The fleet view says it once, above the cards: the daemon restarted at
   a given time and N sessions were lost, dismissible, and absent after a
   live upgrade, which loses nothing.
4. The floor is green and `main` is green after the merge.
