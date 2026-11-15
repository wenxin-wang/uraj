#!/bin/sh
# Device grants on a running box (contained-agent-v2 TODO step 9).
#
# Starts a small box of its own (catatonit, uid 1000, --group-add
# keep-groups so box processes keep the host user's supplementary groups),
# then as the host user, with no root:
#   - attaches /dev/kvm and the first GPU render node with nsmount.py;
#   - in the box, devprobe.py opens each and issues one ioctl (KVM: create
#     a VM; DRM: read the driver version);
#   - the agent (uid 1000) tries mknod before the grant;
#   - detaches /dev/kvm and probes again.
# Mesa needs /sys/dev/char and the GPU's sysfs directory too; not covered.
#
# Run on the host with the contained-podman service running; output to a
# file outside this directory.  KEEP=1 leaves the box running.
set -u

here=$(cd "$(dirname "$0")" && pwd)
W=${W:-$HOME/.cache/devices-probe}
name=devices-box
uid=$(id -u)
if [ -S "/run/contained-podman/$uid/host/podman.sock" ]; then
  host_sock=/run/contained-podman/$uid/host/podman.sock
else
  host_sock=$XDG_RUNTIME_DIR/contained-podman/host/podman.sock
fi
OUT="podman --url unix://$host_sock"
IN="$OUT exec $name"
step() { printf '\n=== %s\n' "$*"; }
result() { printf 'RESULT %-28s %s\n' "$1" "$2"; }
cleanup() {
  [ "${KEEP:-}" = 1 ] && return
  $OUT rm -f -t 0 "$name" >/dev/null 2>&1
  podman unshare rm -rf "$W"
}

step "host side"
ls -l /dev/kvm /dev/dri/renderD* 2>&1
id
render=$(ls /dev/dri/renderD* 2>/dev/null | head -1)

step "tools profile at $W/tools"
mkdir -p "$W"
guix package -p "$W/tools" -i python bash coreutils grep util-linux catatonit \
  >/dev/null || exit 1
T=$(readlink -f "$W/tools")
echo "$T"

step "start box"
$OUT rm -f -t 0 "$name" >/dev/null 2>&1
R=$W/rootfs
podman unshare rm -rf "$R"
for d in bin etc gnu/store probe tmp proc sys dev; do mkdir -p "$R/$d"; done
chmod 1777 "$R/tmp"
ln -s "$T/bin/bash" "$R/bin/sh"
printf 'root:x:0:0::/:/bin/sh\npodman:x:1000:1000::/tmp:/bin/sh\n' \
  > "$R/etc/passwd"
printf 'root:x:0:\npodman:x:1000:\n' > "$R/etc/group"
trap cleanup EXIT
if ! $OUT run --detach --name="$name" \
     --rootfs \
     --userns=keep-id:uid=1000,gid=1000 \
     --user=1000:1000 \
     --group-add=keep-groups \
     --security-opt=label=disable \
     --env=PATH="$T/bin:$T/sbin" \
     --volume=/gnu/store:/gnu/store:ro \
     --volume="$here:/probe:ro" \
     "$R" "$T/bin/catatonit" -- sleep infinity >/dev/null; then
  result box-start failed
  exit 1
fi
box_pid=$($OUT inspect --format '{{.State.Pid}}' "$name")
outer_pid=$($OUT inspect --format '{{.State.ConmonPid}}' "$name")
printf 'groups: conmon %s; box init %s; box exec %s\n' \
  "$(grep '^Groups:' /proc/$outer_pid/status | cut -f2)" \
  "$(grep '^Groups:' /proc/$box_pid/status | cut -f2)" \
  "$($IN grep '^Groups:' /proc/self/status | cut -f2)"

probe() {  # LABEL PATH KIND
  if out=$($IN python3 /probe/devprobe.py "$2" "$3" 2>&1); then
    result "$1" "ok: $out"
  else
    result "$1" "failed: $out"
  fi
}
attach() {  # LABEL SRC
  if "$T/bin/python3" "$here/nsmount.py" attach "$outer_pid" "$box_pid" \
       "$2" "$2"; then
    result "$1" ok
  else
    result "$1" failed
  fi
}

step "before the grant"
probe kvm-before /dev/kvm kvm
if $IN mknod /tmp/kvm c 10 232 2>/dev/null; then
  result agent:mknod succeeded
  probe agent:mknod-node /tmp/kvm kvm
else
  result agent:mknod failed
fi

step "grant /dev/kvm at runtime"
if [ -e /dev/kvm ]; then
  attach kvm-attach /dev/kvm
  probe kvm-after-attach /dev/kvm kvm
else
  result kvm-attach "skipped: no /dev/kvm on the host"
fi

step "grant the render node at runtime"
if [ -n "$render" ]; then
  attach drm-attach "$render"
  probe drm-after-attach "$render" drm
else
  result drm-attach "skipped: no render node on the host"
fi

step "revoke /dev/kvm"
if [ -e /dev/kvm ]; then
  if "$T/bin/python3" "$here/nsmount.py" detach "$outer_pid" "$box_pid" \
       /dev/kvm; then
    result kvm-detach ok
  else
    result kvm-detach failed
  fi
  probe kvm-after-detach /dev/kvm kvm
fi
echo done
