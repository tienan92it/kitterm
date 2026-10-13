# Goal: the fleet view lists the running servers, who started each, and its project

## Objective

At the bottom of `/sessions`, the human sees a SERVERS section: one line
per listening server of the user's processes, with its address
(`localhost:3000`), its program, who started it (the kitterm pane by its
name, the `claude` in a pane, or "outside kitterm" with the launcher),
and the project its cwd resolves to. A server that answers HTTP is a
link that opens it; any other server is plain text. Servers with no pane
and no project fold behind `▶ N other servers`. The daemon answers the
list from the kernel. The request and the choices are
`corpus/00-request.md`.

## Exclusions

- The page holds no action: no stop, no kill, no restart button
  (`sessions-no-input.test.ts`). A server is ended in its pane.
- No port scan of other hosts, and no probe beyond one HTTP request to
  the loopback address of a port the user's own process listens on.
- The band, the panels and the SESSIONS tree do not change, but for the
  room the section takes.
- No `lsof` or `netstat` subprocess on a poll path.
- Linux: the build passes and the route answers an empty list with a
  reason; reading `/proc` is a later goal.

## Completion condition

All 6 hold on a build from `main`:

1. The SERVERS section at 1200 px and 390 px matches the frames of
   `design/sessions.pen` at the commit `corpus/01-approved-design.md`
   names.
2. `GET /api/servers` answers one row per listening TCP port of the
   user's processes but the daemon's own: the port, the addresses it
   binds, the pid, the program, the project, who started it (a session
   by its id and name, through a `claude` or not, else the launcher's
   program), and whether it answers HTTP. It reads the kernel on its own
   queue, cached, never on the event loop; full grade only. Swift tests
   cover a server in a pane (tty), one started by a pane and detached
   (parent chain), and one outside kitterm.
3. A server that answers HTTP is a link to it; a server that does not
   is plain text; the probe has a timeout, is cached per pid and port,
   and runs off the event loop.
4. Servers with a pane or a project are listed; the rest fold behind
   `▶ N other servers`, closed by default.
5. A watch page shows no SERVERS section, as it shows no cost.
6. With no server, the section prints one sentence.

The floor (Linux build, `swift test`, the web checks) is green at every
step.
