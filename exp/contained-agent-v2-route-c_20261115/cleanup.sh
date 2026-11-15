#!/bin/sh
# Route C probe cleanup: stop the test host daemon and the box, then remove
# $W (files owned by subordinate IDs need podman unshare).
set -u

W=${W:-$HOME/.cache/route-c-probe}
uid=$(id -u)
if [ -S "/run/contained-podman/$uid/host/podman.sock" ]; then
  host_sock=/run/contained-podman/$uid/host/podman.sock
else
  host_sock=$XDG_RUNTIME_DIR/contained-podman/host/podman.sock
fi
[ -f "$W/host-daemon.pid" ] && kill "$(cat "$W/host-daemon.pid")" 2>/dev/null
podman --url "unix://$host_sock" rm -f -t 5 route-c-box >/dev/null 2>&1
[ "${KEEP_FILES:-}" = 1 ] || podman unshare rm -rf "$W"
echo "done; remove the test host from the app if you paired it"
