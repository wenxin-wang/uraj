#!/bin/sh
# Route C probe, step 2: a throwaway host daemon that registers the box
# daemon as a connected host, then pairs with the app for a manual check.
#
# The test host daemon has its own PASEO_HOME under $W and listens on
# 127.0.0.1:${HOST_PORT:-16767}; the daemon you normally use is untouched.
# Pairing adds a separate host in the app; remove it there after the probe.
#
#   RELAY=<host>:<port>   relay endpoint for pairing; without it, only the
#                         CLI checks run
#   RELAY_TLS=false       whether the relay uses TLS
set -eu

W=${W:-$HOME/.cache/route-c-probe}
P=$(readlink -f "$W/profile")
HOST_PORT=${HOST_PORT:-16767}
HW=$W/host-home
paseo=$P/bin/paseo
A="$paseo --host 127.0.0.1:$HOST_PORT"
step() { printf '\n=== %s\n' "$*"; }

[ -S "$W/sock/paseo.sock" ] || { echo "run box.sh first" >&2; exit 1; }

step "test host daemon (PASEO_HOME=$HW)"
mkdir -p "$HW"
if [ -f "$W/host-daemon.pid" ] && kill -0 "$(cat "$W/host-daemon.pid")" 2>/dev/null
then
  echo "already running: $(cat "$W/host-daemon.pid")"
else
  # Everything goes into the test home's own config, so later commands
  # given --home "$HW" can never fall back to the default daemon.
  "$paseo" daemon config set daemon.listen "127.0.0.1:$HOST_PORT" --home "$HW"
  if [ -n "${RELAY:-}" ]; then
    "$paseo" daemon config set daemon.relay.enabled true --home "$HW"
    "$paseo" daemon config set daemon.relay.endpoint "$RELAY" --home "$HW"
    "$paseo" daemon config set daemon.relay.useTls "${RELAY_TLS:-false}" \
      --home "$HW"
  else
    "$paseo" daemon config set daemon.relay.enabled false --home "$HW"
  fi
  nohup "$paseo" daemon run --home "$HW" > "$W/host-daemon.log" 2>&1 &
  echo $! > "$W/host-daemon.pid"
fi
for _ in $(seq 60); do $A host ls >/dev/null 2>&1 && break; sleep 1; done
$A host ls

step "register the box daemon"
$A host add "unix://$W/sock/paseo.sock" --label route-c-demo || true
for _ in $(seq 30); do
  $A host ls --json | grep -q '"serverId": *"srv_' && break
  sleep 1
done
$A host ls
$A host ls --json

if [ -n "${RELAY:-}" ]; then
  step "pair the app with the TEST host daemon"
  # Explicit --host: never the daemon you normally use.
  $A daemon pair
  cat <<EOF

In the app, after pairing with this test host:
  1. Does a host labelled after the box appear without adding it by hand?
  2. Is the workspace "route-c-demo" and its mock agent listed?
  3. Open the agent, send a message; does the mock reply stream?
  4. Open a terminal in the workspace; run: hostname; id; pwd; ls /run/box
  5. Browse files and the git diff of /home/podman/work/demo.
  6. Create a new agent there with the mock provider.
Note what works, what is missing, and anything that looks wrong.
EOF
fi
