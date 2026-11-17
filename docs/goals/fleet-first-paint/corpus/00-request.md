# Request: the fleet page paints in under half a second

## The human's words

2026-11-17: "the kitterm session loads too slow. Let's double check app
performance again, benchmark and plan to improve performance and latency".
After the measurements below: "open the goal fleet-first-paint".

## Measurements

The foreman measured on 2026-11-17, on loopback, with daemon v0.50.0. The
live daemon held 8 sessions, 9 projects and 624 archives.

| Surface | Result |
|---|---|
| Fleet page `/sessions`, live daemon, cold caches | first paint about 18.4 s; the page's script and styles arrived in 57 ms |
| Terminal page, fresh shell, scratch daemon | first output at 99 ms; no long task |
| Terminal page, reload with a full 4 MB ring | the 131 KB replay ended at 46 ms |
| `KittermBench`, scratch daemon | PASS; echo p95 2.64 ms; burst 76.8 MB/s |
| `GET /api/version` beside the slow routes | 3 ms maximum; the event loop is not blocked |

## The cause

`poll()` in `Web/terminal/src/sessions.ts` calls `render()` after four
waits in series. The times are from the browser's resource timing on the
cold load.

| Wait | Time | Fact |
|---|---|---|
| `GET /api/archives`, inside the first `Promise.all` | 3,154 ms | 416,340 bytes for 624 rows; the page asks again every 2 s; the route has no `ETag`; a warm answer takes 80 to 90 ms |
| `GET /api/yield` for the stored range "all" | 12,634 ms | the route waits for one `git log` per project on the serial queue `kitterm.yield`; the cache lasts 300 s per root and range, in memory |
| six `GET /api/sessions/<id>` cost reads | about 50 ms | |
| `GET /api/yield/daily` | 2,519 ms | the same queue and cache rule |

After the paint, nine `GET /api/projects/<id>/knowledge` reads took 0.6 to
1.5 s each on the cold load.

The largest fields of `/api/archives` by bytes: `agentTranscript` 87,792;
`labels` 65,060; `project` 53,865; `cwd` 43,073.

## A second cause, on a remote link only

The daemon sends every asset with no compression and `Cache-Control:
public, max-age=3600`, with no `ETag`. The terminal page pulls 699,589
bytes; `main-BDCeJSzg.js` is 617,682 bytes raw and 124,203 bytes with
brotli. This goal does not change that; a chore does.

## Not measured

- A remote link (Tailscale, a phone) and Safari.
- A live pane that runs `claude`: an attach makes the program repaint.
