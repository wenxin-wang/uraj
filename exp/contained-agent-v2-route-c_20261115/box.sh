#!/bin/sh
# Route C probe, step 1: start a box whose only service is a Paseo daemon.
#
# The box daemon listens on the box's own loopback TCP, so agents keep the
# Paseo MCP; socat in the box turns it into a unix socket the host can reach
# at $W/sock/paseo.sock.  catatonit is PID 1 and reaps orphans.  Relay and
# password are off.  No provider credentials go in, so agents cannot run
# here yet (the packaged CLI pins PASEO_NODE_ENV=production, which hides the
# mock provider); workspaces, terminals and files can.  No nested Podman:
# that is box-prototype's job.
#
# Run on the host with the contained-podman service running.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
W=${W:-$HOME/.cache/route-c-probe}
name=route-c-box
uid=$(id -u)
if [ -S "/run/contained-podman/$uid/host/podman.sock" ]; then
  host_sock=/run/contained-podman/$uid/host/podman.sock
else
  host_sock=$XDG_RUNTIME_DIR/contained-podman/host/podman.sock
fi
OUT="podman --url unix://$host_sock"
step() { printf '\n=== %s\n' "$*"; }

$OUT rm -f -t 0 "$name" >/dev/null 2>&1 || true

step "build Guix profile (GC root at $W/profile)"
mkdir -p "$W"
guix package -L "$here/../../src/guix" -L "$here/../../src/guile" \
  -p "$W/profile" \
  -m "$here/manifest.scm" >/dev/null
P=$(readlink -f "$W/profile")
echo "$P"

step "rootfs skeleton"
R=$W/rootfs
podman unshare rm -rf "$R" "$W/sock"
mkdir -p "$W/home/work" "$W/sock"
chmod 700 "$W/sock"
for d in bin usr/bin etc gnu/store home/podman tmp var/tmp run/box proc sys dev
do
  mkdir -p "$R/$d"
done
chmod 1777 "$R/tmp" "$R/var/tmp"
ln -s "$P/bin/bash" "$R/bin/sh"
ln -s "$P/bin/env" "$R/usr/bin/env"
cat > "$R/etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/sh
podman:x:1000:1000:podman:/home/podman:/bin/sh
EOF
cat > "$R/etc/group" <<EOF
root:x:0:
podman:x:1000:
EOF

step "start box"
serve='set -e
socat UNIX-LISTEN:/run/box/paseo.sock,fork,mode=600 TCP:127.0.0.1:6767 &
exec paseo daemon run'
$OUT run --detach --name="$name" \
  --rootfs \
  --userns=keep-id:uid=1000,gid=1000 \
  --user=1000:1000 \
  --security-opt=label=disable \
  --env=PATH="$P/bin:$P/sbin" \
  --env=HOME=/home/podman \
  --env=SHELL="$P/bin/bash" \
  --env=SSL_CERT_DIR="$P/etc/ssl/certs" \
  --env=SSL_CERT_FILE="$P/etc/ssl/certs/ca-certificates.crt" \
  --env=GIT_SSL_CAINFO="$P/etc/ssl/certs/ca-certificates.crt" \
  --env=PASEO_HOME=/home/podman/.paseo \
  --env=PASEO_LISTEN=127.0.0.1:6767 \
  --env=PASEO_RELAY_ENABLED=false \
  --volume=/gnu/store:/gnu/store:ro \
  --volume="$W/home:/home/podman:rw" \
  --volume="$W/sock:/run/box:rw" \
  "$R" "$P/bin/catatonit" -- /bin/sh -c "$serve" >/dev/null
for _ in $(seq 60); do [ -S "$W/sock/paseo.sock" ] && break; sleep 1; done
[ -S "$W/sock/paseo.sock" ] || { $OUT logs "$name" | tail -30; exit 1; }
$OUT top "$name" pid ppid args || true

step "a demo repo inside the box (git runs in the box, not on the host)"
$OUT exec "$name" sh -c 'cd /home/podman/work && rm -rf demo && mkdir demo &&
  cd demo && git init -q && git -c user.name=probe -c user.email=probe@invalid \
  commit -q --allow-empty -m init && git log --oneline'

step "box daemon: CLI inside the box (as an agent there would use it)"
IN_BOX="$OUT exec --env=PASEO_HOST=127.0.0.1:6767 $name paseo"
for _ in $(seq 30); do $IN_BOX workspace ls >/dev/null 2>&1 && break; sleep 1; done
$IN_BOX workspace create --isolation local --path /home/podman/work/demo \
  --title route-c-demo || true
$IN_BOX workspace ls || true
ws=$($IN_BOX workspace ls --json 2>/dev/null \
     | grep -o 'wks_[0-9a-f]*' | head -1 || true)
echo "workspace: ${ws:-none}"
if [ -n "$ws" ]; then
  t=$($IN_BOX terminal create --workspace "$ws" --name probe -q || true)
  echo "terminal: ${t:-none}"
fi

step "box daemon from the host through the socket"
# Always an explicit --host: without it the CLI targets ~/.paseo.
DIRECT="$P/bin/paseo --host unix://$W/sock/paseo.sock"
$DIRECT workspace ls || true
$DIRECT terminal ls --all || true
echo "box ready: $W/sock/paseo.sock"
