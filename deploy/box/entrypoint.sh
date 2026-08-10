#!/usr/bin/env bash
# Bring up the box. Two modes, chosen by whether a tailnet key is present.
#
#   TS_AUTHKEY set  — join the tailnet, put `tailscale serve` in front, and
#                     bind kitterm to loopback with the tailnet name trusted.
#                     Reach it at https://<TS_HOSTNAME>.<tailnet>.ts.net/
#   TS_AUTHKEY unset — bind all interfaces so a published port works.
#                      Reach it at http://localhost:<published>/
#
# Every step announces itself. `docker logs` is the only window into a box that
# failed to come up, so silence there is worse than noise.
set -euo pipefail

# `docker run kitterm-box <cmd>` runs that command instead of starting the box,
# so the image can be inspected without a daemon holding the terminal open.
if [ "$#" -gt 0 ]; then exec "$@"; fi

TS_HOSTNAME="${TS_HOSTNAME:-kitterm-box}"
PORT="${KITTERM_PORT:-3418}"
SOCK=/run/tailscale/tailscaled.sock

say()  { echo "[box] $*"; }
die()  { echo "[box] ERROR: $*" >&2; exit 1; }

# Sessions inherit the daemon's directory, so start it in the workspace —
# otherwise every pane opens in /home/vscode instead of the mounted repo.
WORKSPACE="${KITTERM_CWD:-/workspace}"
as_vscode() {
  su vscode -c "cd $WORKSPACE 2>/dev/null || cd /home/vscode; \
                PATH=$PATH KITTERM_WEB_ROOT=$KITTERM_WEB_ROOT SHELL=/bin/bash $1"
}

if [ -n "${TS_AUTHKEY:-}" ]; then
  say "starting tailscaled (userspace networking)"
  mkdir -p /var/lib/tailscale /run/tailscale
  tailscaled --tun=userspace-networking \
             --state=/var/lib/tailscale/tailscaled.state \
             --socket="$SOCK" >/var/log/tailscaled.log 2>&1 &
  for _ in $(seq 1 30); do [ -S "$SOCK" ] && break; sleep 1; done
  [ -S "$SOCK" ] || die "tailscaled never created its socket. Log:
$(tail -20 /var/log/tailscaled.log 2>/dev/null)"

  say "joining the tailnet as '$TS_HOSTNAME'"
  # --accept-dns=false is load-bearing: MagicDNS would rewrite resolv.conf to
  # 100.100.100.100, which nothing in the box can reach under userspace
  # networking. Every lookup then times out — including the agent's calls to
  # api.anthropic.com. Serve still works; only DNS resolution is declined.
  tailscale --socket="$SOCK" up \
            --authkey="$TS_AUTHKEY" \
            --hostname="$TS_HOSTNAME" \
            --accept-dns=false \
    || die "tailscale up failed — check the key has not expired or been used:
       https://login.tailscale.com/admin/settings/keys"

  # The name kitterm will be reached under. Parse it properly: every peer
  # carries a DNSName too, so grepping the first match can return somebody
  # else's machine. node is already here for the agent.
  say "reading this node's DNS name"
  FQDN=$(tailscale --socket="$SOCK" status --json \
         | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
             try{ process.stdout.write((JSON.parse(s).Self?.DNSName||"").replace(/\.$/,"")) }catch(e){}
           })')
  [ -n "$FQDN" ] || die "joined the tailnet but this node has no DNS name.
       Enable MagicDNS: https://login.tailscale.com/admin/dns
       Then check: tailscale --socket=$SOCK status"
  say "this box is $FQDN"

  say "putting tailscale serve in front of port $PORT"
  tailscale --socket="$SOCK" serve --bg "$PORT" \
    || die "tailscale serve failed. HTTPS certificates must be enabled:
       https://login.tailscale.com/admin/dns"

  # Requests arriving under the tailnet name are treated as remote even though
  # tailscale connects over loopback, so they must present a token — the proxy
  # is a boundary, not a bypass.
  say "starting kitterm, trusting $FQDN"
  as_vscode "kitterm start --port $PORT --agent-control --trusted-host $FQDN" \
    || die "kitterm failed to start"

  TOKEN=$(as_vscode "kitterm token create phone" | tail -1)
  [ -n "$TOKEN" ] || die "could not mint an access token"
  echo
  echo "================================================================"
  echo "  Open this on your phone and your Mac:"
  echo "    https://$FQDN/?token=$TOKEN"
  echo "  Revoke it later with: kitterm token revoke phone"
  echo "================================================================"
  echo
else
  say "no TS_AUTHKEY — local mode, binding all interfaces in this container"
  as_vscode "kitterm start --port $PORT --lan --agent-control" \
    || die "kitterm failed to start"
  TOKEN=$(as_vscode "cat ~/.kitterm/token")
  [ -n "$TOKEN" ] || die "daemon started but wrote no token"
  echo
  echo "================================================================"
  echo "  No TS_AUTHKEY set — serving on the container's port $PORT."
  echo "  If you published it as -p 4990:$PORT, open:"
  echo "    http://localhost:4990/?token=$TOKEN"
  echo "================================================================"
  echo
fi

say "box is up; leave this container running"
# Keep the container alive; the daemon and its shells run detached.
tail -f /dev/null
