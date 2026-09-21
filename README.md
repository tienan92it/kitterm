<div align="center">

# kitterm

**A terminal daemon with a ledger.**

[![Release](https://img.shields.io/github/v/release/tienan92it/kitterm?color=3fb950)](https://github.com/tienan92it/kitterm/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20%7C%20Linux-lightgrey)](https://github.com/tienan92it/kitterm)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

kitterm is a terminal daemon with a ledger: your Mac's shell in any browser
tab, alive after the tab closes. A dashboard says what every agent in it is
doing, what it cost, and what it shipped.

## Install

```sh
curl -fsSL https://kitterm.dev/install.sh | sh
kitterm start
# → http://kitterm.localhost:3418/
```

`kitterm upgrade` installs the latest release.
`kitterm upgrade --live` takes over in place — same pid, same shells,
no dropped panes.

See [Linux](#linux) below for containers and cloud boxes.

## Terminal

A tab is a real shell with a controlling TTY: job control, `Ctrl+C`, and TUIs
work as they would in a native terminal app. Close the tab and the shell
keeps running.

- **Reattach from any device.** Open the session's link from your phone or a
  second laptop and pick up where you left off. A reconnect replays exactly
  the bytes you missed, from a 4 MiB per-session output ring.
- **Splits.** `⌘D` / `⌘⇧D` split a pane; `⌘⌥T` opens a new tab in the same
  directory.
- **Session profiles** name a connect command in `~/.kitterm/profiles.json`
  (`{"profiles":[{"name":"vm","command":"ssh dev-vm"}]}`), so `/?profile=vm`
  or a click in `/sessions` opens a tab that is that remote shell.
- **Linux** puts an agent in a container that outlives your laptop. The
  tarball is statically linked, so the host needs no Swift toolchain.

### Linux

```sh
V=v0.31.0; ARCH=amd64        # or arm64
curl -fsSL -o kitterm.tar.gz \
  https://github.com/tienan92it/kitterm/releases/download/$V/kitterm-$V-linux-$ARCH.tar.gz
sudo tar -xzf kitterm.tar.gz -C /usr/local

kitterm integrate bash >> ~/.bashrc   # shell integration is not optional here
kitterm start --agent-control
```

A bare container's shell emits no OSC 133 marks, so without the integration
snippet `⌘↑`/`⌘↓` do nothing and `/api/sessions/<id>/commands` stays empty.
There is no launchd on Linux, so `kitterm start` detaches the daemon from
your shell rather than rooting it in a login session; use your init system,
or `restart: unless-stopped` in a container. Reaching it from outside a
Tailscale or reverse-proxy setup needs `--trusted-host <name>` and a token.

For a container with this already wired up, see
[kitbox](https://github.com/tienan92it/kitbox).

## Dashboard

`/sessions` is a dashboard, not a control panel: it presents and monitors,
and holds no typed input of its own. You act on an agent by opening its pane.

The band at the top gives four counts — working, needing you, the range's
spend, and the current window's quota share — plus the brand.

**USAGE** charts cost or tokens per day over 7, 30, or 90 days.
**QUOTA** draws one bar per Claude Code rate-limit window, with its reset
time and its age.
**VALUE** counts merged pull requests, merged lines, releases, and hours of
model time, each with its unit cost — proxies for value, not value.
**WHERE** breaks the range's spend down by project, goal, task, or role.
**MODELS** lists the top three models by cost, with the rest folded into one
row.
**LEAKS** names the spend nothing else can attribute: rounds with no cost
line, and sessions under 95% cached.

Every figure on the page follows the one range that USAGE's toggles set.

Below the panels sits the tree: workspaces, then projects, then goals, then
tasks, then the sessions under each. A goal or task carries its state
(`[working]`, `[needs you]`, `[done]`, …) and its cost in the range. A
running session has no bill yet, so its cost column shows a running estimate,
`~$4.20`, until the bill lands.

## The foreman and crew

`docs/goals/` is the control plane for agent work on this repository. Each
goal is one folder — `goal.md`, `plan.md`, `STATE.md`, `corpus/`, `rounds/` —
and a goal's status lives in its `STATE.md`.

One foreman runs per daemon, in a pane of its own, on the kitterm MCP tools.
It reads every goal's `STATE.md` and spawns one crew session per round to do
the work. It writes one record under `rounds/` when the round ends.
`kitterm goal new <path> <slug>` writes a new goal folder from the template.

The record names the round's cost. The record also names the round's pull
request, so a goal's ledger reads as cost and result per round, not a guess
at total effort.

## The MCP bridge

`kitterm mcp` is a stdio MCP server that hands an agent the foreman toolset:
`list_sessions`, `get_session`, `spawn_session`, `rename_session`,
`send_input`, `list_commands`, `wait_for_command`, `read_output`,
`read_screen`, `wait_for_events`, `post_note`, `list_approvals`,
`kill_session`, `archive_session`, `list_archives`, `list_projects`.

Register it once with `claude mcp add kitterm -- kitterm mcp`, or add it
directly to `.mcp.json`:

```json
{
  "mcpServers": {
    "kitterm": {
      "command": "kitterm",
      "args": ["mcp"]
    }
  }
}
```

The tools that drive shells need `--agent-control` on the daemon.

## Statusline

`kitterm statusline install` wraps the Claude Code statusline command. It
then posts the quota reading — the `rate_limits` object Claude Code already
hands the statusline script — to the daemon on every render. `/sessions`
draws the QUOTA panel from it.

## Security

kitterm binds `127.0.0.1` by default; `--lan` is the only path that widens
it, and it requires a token. A **watch** token can observe sessions and
read the API, but only a **full** token can type, take control, or spawn a
shell. `--agent-control` gates the routes that spawn a session and type
into one — off by default, since it lets any admitted client drive a shell
as your user.

## Building from source

For the parts, the session lifecycle, and the data flows, see
[docs/architecture.md](docs/architecture.md).

Requires Swift 6 and Node 22+ with pnpm.

```sh
swift build
(cd Web/terminal && pnpm install && pnpm build)
swift run kitterm start
```

`swift test` runs the Swift suite. On Linux, `swift build` works but `swift
test` does not — several test files use `Bundle(for:)`, which
corelibs-XCTest has no equivalent for.

## License

[MIT](LICENSE) · Inspired by [localterm](https://github.com/millionco/localterm)
