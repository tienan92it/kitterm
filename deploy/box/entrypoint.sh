#!/usr/bin/env bash
# Bring up the box. Two modes, chosen by whether a tailnet key is present.
#
#   TS_AUTHKEY set  — join the tailnet, put `tailscale serve` in front, and
#                     bind kitterm to loopback with the tailnet name trusted.
#                     Reach it at https://<TS_HOSTNAME>.<tailnet>.ts.net/
#   TS_AUTHKEY unset — bind all interfaces so a published port works.
#                      Reach it at http://localhost:<published>/
set -euo pipefail

# `docker run kitterm-box <cmd>` runs that command instead of starting the box,
# so the image can be inspected without a daemon holding the terminal open.
if [ "$#" -gt 0 ]; then exec "$@"; fi

TS_HOSTNAME="${TS_HOSTNAME:-kitterm-box}"
PORT="${KITTERM_PORT:-3418}"
SOCK=/run/tailscale/tailscaled.sock

# Sessions inherit the daemon's directory, so start it in the workspace —
# otherwise every pane opens in /home/vscode instead of the mounted repo.
WORKSPACE="${KITTERM_CWD:-/workspace}"
as_vscode() {
  su vscode -c "cd $WORKSPACE 2>/dev/null || cd /home/vscode; \
                PATH=$PATH KITTERM_WEB_ROOT=$KITTERM_WEB_ROOT SHELL=/bin/bash $1"
}

if [ -n "${TS_AUTHKEY:-}" ]; then
  mkdir -p /var/lib/tailscale /run/tailscale
  tailscaled --tun=userspace-networking \
             --state=/var/lib/tailscale/tailscaled.state \
             --socket="$SOCK" >/var/log/tailscaled.log 2>&1 &
  for _ in $(seq 1 30); do [ -S "$SOCK" ] && break; sleep 1; done
  tailscale --socket="$SOCK" up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"

  # The name kitterm will be reached under. Requests arriving under it are
  # treated as remote even though tailscale connects over loopback, so they
  # must present a token — the proxy is a boundary, not a bypass.
  FQDN=$(tailscale --socket="$SOCK" status --json | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4)
  FQDN=${FQDN%.}
  tailscale --socket="$SOCK" serve --bg "$PORT"

  as_vscode "kitterm start --port $PORT --agent-control --trusted-host $FQDN"
  TOKEN=$(as_vscode "kitterm token create phone" | tail -1)
  echo
  echo "================================================================"
  echo "  Open this on your phone and your Mac:"
  echo "    https://$FQDN/?token=$TOKEN"
  echo "  Revoke it later with: kitterm token revoke phone"
  echo "================================================================"
  echo
else
  as_vscode "kitterm start --port $PORT --lan --agent-control"
  TOKEN=$(as_vscode "cat ~/.kitterm/token")
  echo
  echo "================================================================"
  echo "  No TS_AUTHKEY set — serving on the container's port $PORT."
  echo "  If you published it as -p 4990:$PORT, open:"
  echo "    http://localhost:4990/?token=$TOKEN"
  echo "================================================================"
  echo
fi

# Keep the container alive; the daemon and its shells run detached.
tail -f /dev/null
