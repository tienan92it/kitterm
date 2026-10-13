# The human's request

2026-10-13, in the foreman's pane:

> at the bottom of dashboard, can it shows list of running servives or
> servers include their name, who has started it? which project does it
> belong to?. Like: localhost:3007, localhost:3002, localhost:5432...
> They should be clickable to open

The foreman's facts, the same day (`lsof -nP -iTCP -sTCP:LISTEN` as the
user, then `ps` and the cwd of each process):

| Port | Process | Started by | Project from the cwd |
|---|---|---|---|
| 3000, 4646 | `next-server` | node, no kitterm pane | `foundation-apps` (`apps/memo`, `apps/home`) |
| 8010 | `python` | `uv`, no pane | `NgheNhanTrading/trading-data-api` |
| 3003 | `kubectl` | `claude` in a kitterm pane | `NgheNhanTrading/market-data-pipeline` |
| 5432 | `postgres` | a kitterm pane, tty `ttys014` | none (`~/.lume-cafe/pgdata`) |
| 6379 | `redis-server` | launchd (Homebrew) | none |
| 5000, 7000, 55618, 6463, 56174 | ControlCenter, rapportd, Discord, Notion | macOS and apps | none |

A server is traced to a pane by its controlling tty (the pane's PTY), else
by its parent chain (a pane's shell, or a `claude` under one), and to a
project by its cwd, the rule session rows use.

The human's choices, 2026-10-13:

1. **Scope: attributed, then a fold.** The list shows every server
   started from a kitterm pane or whose cwd is in a project. The rest
   (ControlCenter, rapportd, Discord, Homebrew redis) fold behind
   `▶ N other servers`.
2. **Links: HTTP servers only.** The daemon probes each port with one
   HTTP request, off the event loop and cached. A server that answers
   HTTP is a link; postgres and redis stay plain text.
3. **Design: a browser draft, then Pen.** One quick HTML draft from the
   real list for the human's choice; the approved draft then goes into
   `design/sessions.pen`, edited headless.
