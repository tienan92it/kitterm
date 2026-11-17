# Goal: the fleet page paints in under half a second

## Objective

The human opens `/sessions` and sees the sessions, the projects and the
approvals in under half a second, whatever the state of the daemon's
caches. On 2026-11-17 that first paint took about 18.4 s on loopback
(`corpus/00-request.md`), because the page waits for the archives, the
yield and the bills before it renders. After this goal, the page paints
the fleet first and each slower section fills in when its own answer
arrives. No route makes a request wait for `git`, and the archive list
costs bytes only when it changed.

## Exclusions

- No change to the terminal page, the WebSocket path or the output ring.
  They measured fast.
- No compression, no cache headers and no bundle split for the static
  assets. That work is a chore; it touches the release layout.
- No change to what the page shows once every section has its answer:
  the same numbers, the same order, the same words.
- No new dependency in `Web/terminal/package.json` or `Package.swift`.
- No change to what a watch token may read.

## Charter

The human approved the plan on 2026-11-17 with the words "open the goal
fleet-first-paint" (`corpus/00-request.md`). That approval charters the
rounds of this goal to replace an assertion in an existing test file
that pins one of these, and to keep its intent:

- the page asks `/api/archives` in every poll, or renders only after the
  archives, the usage, the yield, the bills or the lifetime answered;
- `/api/yield` or `/api/yield/daily` answers only after `git` ran;
- the body of `/api/archives`, when the round moves a field out of it.

## Completion condition

All six hold on the goal's branch:

1. With `/api/archives`, `/api/usage/daily`, `/api/yield`,
   `/api/yield/daily` and every `/api/sessions/<id>/cost` stalled, the
   page renders the sessions, the projects and the approvals after the
   answers of `/api/sessions`, `/api/projects`, `/api/approvals` and
   `/api/usage/limits`. A page test pins this.
2. Each section that waits shows that it waits, and paints by itself when
   its answer arrives. A failed answer of one section leaves the other
   sections on the page. A page test pins each of the four sections.
3. `GET /api/yield` and `GET /api/yield/daily` never wait for `git`: with
   no answer kept they answer at once and say that the read is pending,
   and they start one read. An answer older than the interval is served
   while one refresh runs. The kept answers live on disk, so the first
   request after a restart is served from them. A test pins each case
   with a `git` stub that blocks.
4. `GET /api/archives` carries an `ETag` and answers 304 to a matching
   `If-None-Match`. The daemon does not read the archive directory again
   for a list that did not change. The page does not ask for the
   archives in every poll: it asks once after the paint, and again when
   an archive event arrives or the fold opens. A test pins each.
5. One deterministic check holds the budget: with a fixture of 600
   archives and a yield that never answers, the page's first paint of the
   fleet needs no answer beyond the four of condition 1. The foreman
   measures the live page after the last round; the record gives the
   first-paint time, and it is under 500 ms on loopback.
6. `docs/http-api.md` describes the new answers of the three routes.
   `swift test`, `pnpm test` and `pnpm build` are green, `KittermBench`
   passes, and the pull request's `ci.yml` run is green.
