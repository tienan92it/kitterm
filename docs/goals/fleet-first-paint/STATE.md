# STATE: fleet-first-paint

- Status: done
- Round: 3 of 3 in this budget (first budget)
- Rounds total: 3
- Last floor: green (2026-11-17, round 3)
- Updated: 2026-11-17

## Queue

None.

## Failures

None.

## Proposals waiting on the human

- A chore for the static assets: compress at build, serve hashed files
  as `immutable`, and split the preview and highlight code out of
  `main` (`corpus/00-request.md`, "A second cause"). It touches the
  release layout.
- A release and `kitterm upgrade --live`, so the live daemon serves this
  goal's work.
- The first load with nothing kept asks `/api/yield/daily` every 2 s
  until its figures are complete (`rounds/003.md`, "Gap"). A longer
  step, or an answer that carries only the roots that changed, is a
  chore.

## Done

- `paint-first`, round 1, `399c53b`, PR #220. See `rounds/001.md`.
- `yield-never-waits`, round 2, `f8302f4`, PR #220. See `rounds/002.md`.
- `archives-cheap`, round 3, `deeab81`, PR #220. See `rounds/003.md`.

## Next action

None. The goal is done: the first paint of `/sessions` is 200 ms with
every cache cold (`rounds/003.md`). To reopen, set `Status: active` and
write a new queue.
