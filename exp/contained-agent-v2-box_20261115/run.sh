#!/bin/sh
# One-off probe: can the outer runtime ("box") use a Guix profile instead of
# quay.io/podman/stable, and still run nested rootless Podman with a full
# subordinate-ID range (Postgres, published ports)?
#
# Run on the host, in a normal terminal, with the contained-podman service
# running.  Flags mirror the runtime launch in
# src/python/uraj/contained_podman.py; differences are marked "PROBE".
# Leaves everything under $W; KEEP=1 keeps the box running afterwards;
# DIAG=1 only compares setuid and file-capability newuidmap copies.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
W=${W:-$HOME/.cache/guix-box-probe}
name=guix-box-probe
uid=$(id -u)
if [ -S "/run/contained-podman/$uid/host/podman.sock" ]; then
  host_sock=/run/contained-podman/$uid/host/podman.sock
else
  host_sock=$XDG_RUNTIME_DIR/contained-podman/host/podman.sock
fi
OUT="podman --url unix://$host_sock"
IN="podman --url unix://$W/api/podman.sock"
step() { printf '\n=== %s\n' "$*"; }
result() { printf 'RESULT %-28s %s\n' "$1" "$2" | tee -a "$W/results"; }

step "host service: $host_sock"
$OUT info --format 'rootless={{.Host.Security.Rootless}} uidmap={{.Host.IDMappings.UIDMap}}'

mkdir -p "$W"
: > "$W/results"
$OUT rm -f "$name" >/dev/null 2>&1 || true

step "build Guix profile (GC root at $W/profile)"
guix package -p "$W/profile" -m "$here/manifest.scm" >/dev/null
P=$(readlink -f "$W/profile")
echo "$P"

step "rootfs skeleton"
R=$W/rootfs
# Earlier runs leave files owned by subordinate IDs; same map as the service.
podman unshare rm -rf "$R" "$W/api" "$W/storage" "$W/inner-run"
mkdir -p "$W/api" "$W/storage" "$W/inner-run"
chmod 700 "$W/api" "$W/storage" "$W/inner-run"
for d in bin usr/bin etc/containers gnu/store home/podman tmp var/tmp \
         run/user proc sys dev; do
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
# Same ranges as the Fedora image: everything but the keep-id service UID.
printf 'podman:1:999\npodman:1001:64535\n' > "$R/etc/subuid"
cp "$R/etc/subuid" "$R/etc/subgid"
cat > "$R/etc/containers/policy.json" <<EOF
{"default": [{"type": "insecureAcceptAnything"}]}
EOF
cat > "$R/etc/containers/registries.conf" <<EOF
unqualified-search-registries = ["docker.io"]
short-name-mode = "permissive"
EOF
# Same as inner-containers.conf, plus where Guix keeps the helpers.
cat > "$R/etc/containers/containers.conf" <<EOF
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
helper_binaries_dir = ["$P/bin", "$P/libexec/podman"]
[containers]
cgroups = "enabled"
cgroup_parent = "/tasks"
[network]
network_backend = "netavark"
EOF
cat > "$R/etc/containers/storage.conf" <<EOF
[storage]
driver = "overlay"
graphroot = "/home/podman/.local/share/containers/storage"
runroot = "/run/user/1000/storage"
EOF

step "nested seccomp profile (base from the current runtime image)"
image=$($OUT images --format '{{.Repository}}@{{.Digest}}' quay.io/podman/stable | head -1)
$OUT run --rm --cgroups=disabled --network=none --entrypoint=/bin/cat \
  "$image" /usr/share/containers/seccomp.json > "$W/seccomp-base.json"
PYTHONPATH=$repo/src/python python3 -c '
import json, sys
from uraj.contained_podman import nested_seccomp
print(json.dumps(nested_seccomp(json.load(open(sys.argv[1])))))
' "$W/seccomp-base.json" > "$W/seccomp-nested.json"

step "cgroup"
cg=/sys/fs/cgroup/contained-podman-$name
mkdir -p "$cg"
echo '+cpu +memory +pids' > "$cg/cgroup.subtree_control"

step "start box"
inner='set -e
test "$(id -u)" = 1000
mkdir /sys/fs/cgroup/service /sys/fs/cgroup/tasks
echo $$ > /sys/fs/cgroup/service/cgroup.procs
echo "+cpu +memory +pids" > /sys/fs/cgroup/cgroup.subtree_control
echo "+cpu +memory +pids" > /sys/fs/cgroup/tasks/cgroup.subtree_control
exec podman system service --time=0 unix:///run/api/podman.sock'
# PROBE: /gnu/store has no setuid bits or file capabilities; namespace root
# makes copies on a suid tmpfs, where the Guix podman wrapper already looks.
# Setuid copies get EPERM writing uid_map (DIAG=1); file capabilities, as in
# the Fedora image, work.
outer='set -e
test "$(id -u)" = 0
cp '"$P"'/bin/newuidmap '"$P"'/bin/newgidmap /run/privileged/bin/
setcap cap_setuid+ep /run/privileged/bin/newuidmap
setcap cap_setgid+ep /run/privileged/bin/newgidmap
chown 1000:1000 /sys/fs/cgroup /sys/fs/cgroup/cgroup.procs \
  /sys/fs/cgroup/cgroup.threads /sys/fs/cgroup/cgroup.subtree_control
# PROBE: Guix util-linux has no setpriv; unshare without namespace flags
# only drops supplementary groups and switches IDs.
exec unshare --setgid=1000 --setuid=1000 /bin/sh -ec "$0"'
if [ "${DIAG:-}" = 1 ]; then
  # Why does newuidmap get EPERM?  Compare setuid and file capabilities.
  outer='set -x
cp '"$P"'/bin/newuidmap /run/privileged/bin/
cp '"$P"'/bin/newuidmap /run/privileged/bin/newuidmap-fcap
cp '"$P"'/bin/id /run/privileged/bin/suid-id
chmod 4755 /run/privileged/bin/newuidmap /run/privileged/bin/suid-id
setcap cap_setuid+ep /run/privileged/bin/newuidmap-fcap
getcap /run/privileged/bin/newuidmap-fcap
exec unshare --setgid=1000 --setuid=1000 /bin/sh -c "$0"'
  inner='set -x
id
grep -E "NoNewPrivs|Seccomp:|Cap(Prm|Eff|Bnd)" /proc/self/status
findmnt -no FSTYPE,OPTIONS /run/privileged/bin
ls -ln /run/privileged/bin
cat /proc/self/uid_map
/run/privileged/bin/suid-id
for t in newuidmap newuidmap-fcap; do
  unshare --user sleep 20 & pid=$!
  sleep 1
  /run/privileged/bin/$t $pid 0 1000 1 1 1 999 && cat /proc/$pid/uid_map
  kill $pid
done
true'
fi
tun=
[ -e /dev/net/tun ] && tun=--device=/dev/net/tun
# shellcheck disable=SC2086
$OUT run --detach --name="$name" \
  --rootfs \
  --cgroups=enabled \
  --userns=keep-id:uid=1000,gid=1000 \
  --user=0:0 \
  --security-opt=label=disable \
  --security-opt=unmask=ALL \
  --security-opt=seccomp="$W/seccomp-nested.json" \
  --device=/dev/fuse $tun \
  --env=PATH="/run/privileged/bin:$P/bin:$P/sbin" \
  --env=HOME=/home/podman \
  --env=XDG_RUNTIME_DIR=/run/user/1000 \
  --env=SSL_CERT_DIR="$P/etc/ssl/certs" \
  --env=SSL_CERT_FILE="$P/etc/ssl/certs/ca-certificates.crt" \
  --cgroup-parent="/contained-podman-$name" \
  --cgroupns=private \
  --systemd=always \
  --stop-signal=SIGTERM \
  --tmpfs=/run/privileged/bin:rw,exec,suid,mode=0755 \
  --volume=/gnu/store:/gnu/store:ro \
  --volume="$W/inner-run:/run/user/1000:rw" \
  --volume="$W/api:/run/api:rw" \
  --volume="$W/storage:/home/podman/.local/share/containers:rw" \
  "$R" /bin/sh -c "$outer" "$inner" >/dev/null
if [ "${DIAG:-}" = 1 ]; then
  sleep 8
  $OUT logs "$name"
  $OUT rm -f -t 0 "$name" >/dev/null
  rmdir "$cg" 2>/dev/null || true
  exit 0
fi
for _ in $(seq 30); do [ -S "$W/api/podman.sock" ] && break; sleep 1; done
if $IN info --format 'uidmap={{.Host.IDMappings.UIDMap}}'; then
  result box-starts ok
else
  result box-starts FAIL
  $OUT logs "$name" | tail -30
  exit 1
fi
$OUT exec --user 1000 "$name" ls -l /run/privileged/bin

step "Postgres (entrypoint drops to UID 70)"
if $IN run -d --name pg -e POSTGRES_PASSWORD=probe \
     docker.io/library/postgres:17-alpine >/dev/null; then
  ok=
  for _ in $(seq 60); do
    if $IN exec pg pg_isready -U postgres >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  $IN exec pg sh -c 'ps -o user,args | head -3' || true
  if [ -n "$ok" ]; then result postgres ok
  else result postgres FAIL; $IN logs pg | tail -20; fi
else
  result postgres FAIL
fi

step "Compose-style DNS between containers"
$IN network create probe-net >/dev/null
$IN run -d --name web --network probe-net docker.io/library/nginx:alpine >/dev/null
sleep 2
if $IN run --rm --network probe-net docker.io/library/alpine:latest \
     wget -qO- http://web/ | grep -q nginx; then
  result network-dns ok
else
  result network-dns FAIL
fi

step "published port, seen from a process in the box (where an agent would run)"
$IN run -d --name pub -p 18080:80 docker.io/library/nginx:alpine >/dev/null
sleep 2
if $OUT exec --user 1000 "$name" curl -fsS -m 5 http://127.0.0.1:18080/ \
     | grep -q nginx; then
  result published-port-in-box ok
else
  result published-port-in-box FAIL
fi

step "Guix inside the box (needs the daemon socket; expected to be absent)"
if $OUT exec --user 1000 "$name" sh -c 'command -v guix'; then
  result guix-in-box present
else
  result guix-in-box absent
fi

step "summary"
cat "$W/results"
$OUT exec --user 1000 "$name" podman info \
  --format 'inner: {{.Host.OCIRuntime.Name}} {{.Store.GraphDriverName}} {{.Host.NetworkBackend}}' \
  2>/dev/null || true

if [ "${KEEP:-}" != 1 ]; then
  step "cleanup"
  $IN rm -af -t 0 >/dev/null 2>&1 || true
  $OUT rm -f -t 5 "$name" >/dev/null
  rmdir "$cg" 2>/dev/null || echo "cgroup $cg still busy; remove it later"
  echo "kept $W (profile GC root and image cache); rm -rf it when done"
fi
