#!/bin/sh
# Rootless runtime grants on a running box (contained-agent-v2 TODO step 8).
#
# As the host user, with no root:
#   (a) nftables in the box's netns: block the host (169.254.1.2) and
#       private ranges, keep public and the relay; then remove the rules;
#   (b) attach a host directory to the running box, then detach it, and
#       check whether an fd opened before the detach still reads;
#   (c) the agent in the box (uid 1000) tries to undo or repeat (a), (b).
#
# Needs the route C box: run exp/contained-agent-v2-route-c_20261115/box.sh
# first, cleanup.sh there afterwards.  Run on the host, in a normal
# terminal, output to a file outside this directory.
#   RELAY_PROBE=host:port  relay; stays reachable (its IP is allowed)
#   LAN_PROBE=host:port    another LAN machine; should become blocked
set -u

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
IN="$OUT exec $name"
step() { printf '\n=== %s\n' "$*"; }
result() { printf 'RESULT %-28s %s\n' "$1" "$2"; }

if ! $IN true 2>/dev/null; then
  echo "box $name is not running; run route-c box.sh first"
  exit 1
fi

step "tools profile (nftables, util-linux, python) at $W/tools"
guix package -p "$W/tools" -i nftables util-linux python >/dev/null || exit 1
T=$(readlink -f "$W/tools")
echo "$T"

box_pid=$($OUT inspect --format '{{.State.Pid}}' "$name")
outer_pid=$($OUT inspect --format '{{.State.ConmonPid}}' "$name")
step "namespaces (box init $box_pid, conmon $outer_pid)"
for p in self "$outer_pid" "$box_pid"; do
  printf '%-8s user=%s net=%s mnt=%s\n' "$p" \
    "$(readlink /proc/$p/ns/user)" "$(readlink /proc/$p/ns/net)" \
    "$(readlink /proc/$p/ns/mnt)"
done
# Enter through the outer (rootless Podman) user namespace: the host user
# owns it, and it is an ancestor of whichever user namespace owns the netns.
NFT="$T/bin/nsenter --user=/proc/$outer_pid/ns/user \
  --net=/proc/$box_pid/ns/net -- $T/sbin/nft"

# probe LABEL URL: classify by curl's exit code.
probe() {
  $IN curl -s -o /dev/null -m 5 "$2"
  rc=$?
  case $rc in
    0) r=open ;;
    7) r="refused or unreachable" ;;
    28) r="no answer in 5 s" ;;
    *) r="curl exit $rc" ;;
  esac
  result "$1" "$r"
}

probes() {
  probe "$1:host-0.0.0.0" "http://169.254.1.2:18182/"
  probe "$1:public" "https://example.com/"
  [ -n "${LAN_PROBE:-}" ] && probe "$1:lan" "http://$LAN_PROBE/"
  [ -n "${RELAY_PROBE:-}" ] && probe "$1:relay" "http://$RELAY_PROBE/"
}

step "(a) nftables in the box netns"
"$T/bin/python3" -m http.server --bind 0.0.0.0 18182 >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
sleep 1
probes before

relay_ip=${RELAY_PROBE%:*}
allow=""
[ -n "${RELAY_PROBE:-}" ] && allow="ip daddr $relay_ip accept"
# 169.254.1.1 is pasta's DNS forwarder; leave it alone.
if printf '%s\n' "table inet boxgrant {
  chain out {
    type filter hook output priority 0; policy accept;
    $allow
    ip daddr 169.254.1.2 reject
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } reject
  }
}" | $NFT -f -; then
  result nft-add ok
  $NFT list table inet boxgrant
else
  result nft-add failed
fi
probes with-rules

step "(c) the agent in the box against the rules"
for c in "nft list ruleset" "nft flush ruleset" \
         "nsenter --net=/proc/1/ns/net nft flush ruleset" \
         "unshare -Urn nft list ruleset" \
         "unshare -Ur nsenter --net=/proc/1/ns/net nft flush ruleset"; do
  # shellcheck disable=SC2086
  if out=$($IN sh -c "PATH=$T/bin:$T/sbin:\$PATH; $c" 2>&1); then
    result "agent:$c" "succeeded"
  else
    result "agent:$c" "failed"
  fi
  printf '  %s\n' "$out" | head -3
done
probe agent-after:host-0.0.0.0 "http://169.254.1.2:18182/"

if $NFT delete table inet boxgrant; then
  result nft-delete ok
else
  result nft-delete failed
fi
probes after-delete

step "(b) attach a host directory to the running box"
src=$W/grant-src
mkdir -p "$src"
echo "from the host" > "$src/hello"
dst=/home/podman/granted
$IN mkdir -p "$dst"
if "$T/bin/python3" "$here/nsmount.py" attach "$outer_pid" "$box_pid" \
     "$src" "$dst"; then
  result mount-attach ok
else
  result mount-attach failed
fi
if [ "$($IN cat "$dst/hello" 2>&1)" = "from the host" ]; then
  result mount-visible yes
else
  result mount-visible no
fi
if $IN touch "$dst/written-in-box" 2>/dev/null; then
  result mount-writable "yes, host sees owner $(stat -c %u:%g \
    "$src/written-in-box" 2>/dev/null)"
else
  result mount-writable no
fi
$IN grep " $dst " /proc/self/mountinfo | head -2

step "(c) the agent in the box against mounts"
if $IN sh -c "PATH=$T/bin:$T/sbin:\$PATH; umount $dst" 2>/dev/null; then
  result agent:umount succeeded
else
  result agent:umount failed
fi
if $IN sh -c "PATH=$T/bin:$T/sbin:\$PATH; mount --bind /tmp /home/podman" \
     2>/dev/null; then
  result agent:bind-mount succeeded
else
  result agent:bind-mount failed
fi

step "(b) detach while a box process holds an fd"
$IN sh -c "exec 3<$dst/hello; echo \$\$ > /tmp/holder; exec sleep 60" &
hold_job=$!
sleep 2
holder=$($IN cat /tmp/holder)
if "$T/bin/python3" "$here/nsmount.py" detach "$outer_pid" "$box_pid" \
     "$dst"; then
  result mount-detach ok
else
  result mount-detach failed
fi
if $IN test -e "$dst/hello"; then
  result path-after-detach "still visible"
else
  result path-after-detach gone
fi
if [ "$($IN cat "/proc/$holder/fd/3" 2>&1)" = "from the host" ]; then
  result held-fd-after-detach "still reads"
else
  result held-fd-after-detach "no longer reads"
fi
$IN kill "$holder" 2>/dev/null
wait "$hold_job" 2>/dev/null
echo done
