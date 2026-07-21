# launchd user agent

Optional auto-start for the kitterm daemon as a per-user LaunchAgent.

The agent runs `kitterm serve` in the foreground so launchd owns the process lifecycle. Do **not** use `kitterm start` here — that forks a detached child and confuses KeepAlive.

## Install

```bash
kitterm service install     # writes the plist and bootstraps it
kitterm service status
```

That generates the plist below with the correct absolute path already filled in,
so the steps that follow are only needed if you want to manage it by hand.

### Manual alternative

1. Build a release binary and put it somewhere stable:

```bash
cd /path/to/kitterm
swift build -c release
cp .build/release/kitterm /usr/local/bin/kitterm   # or another absolute path
```

2. Copy and edit the plist — set `ProgramArguments[0]` to that absolute path:

```bash
mkdir -p ~/Library/LaunchAgents
cp launchd/com.kitterm.daemon.plist ~/Library/LaunchAgents/
# edit ~/Library/LaunchAgents/com.kitterm.daemon.plist
```

3. Load the agent (macOS 13+):

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.kitterm.daemon.plist
launchctl enable gui/$(id -u)/com.kitterm.daemon
```

4. Verify:

```bash
kitterm status
# or
curl -s -H 'Host: 127.0.0.1:3418' http://127.0.0.1:3418/api/health
```

Logs: `~/.kitterm/server.log` (written by `serve`).

## Uninstall

```bash
kitterm service uninstall
```

Or by hand:

```bash
launchctl bootout gui/$(id -u)/com.kitterm.daemon
rm -f ~/Library/LaunchAgents/com.kitterm.daemon.plist
```

## Notes

- Binds loopback only (`127.0.0.1`). See the main README security section.
- Change `--port` in the plist if you do not use the default `3418`.
- If you already run `kitterm start` manually, stop it before loading the agent to avoid port conflicts.
