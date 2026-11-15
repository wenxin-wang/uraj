#!/bin/sh
# What can a process in the 106 box reach?  Host loopback, host LAN address,
# another LAN host, the Paseo daemon port, the Paseo relay, the public
# internet; plus how pasta was configured for the box.
#
# Run on the host after `KEEP=1 exp/contained-agent-v2-box_20261115/run.sh`
# left the box running.  Only TCP connects and HTTP GETs; the daemon probe
# sends one GET to its root and nothing else.
#
#   LAN_PROBE=<lan-host>:<port>   another LAN host, e.g. the router's web UI
#   RELAY_PROBE=<host>:<port>     the Paseo relay endpoint
#   PASEO_PROBE=127.0.0.1:6767    the host daemon's listen address
set -eu

PASEO_PROBE=${PASEO_PROBE:-127.0.0.1:6767}
name=guix-box-probe
uid=$(id -u)
if [ -S "/run/contained-podman/$uid/host/podman.sock" ]; then
  host_sock=/run/contained-podman/$uid/host/podman.sock
else
  host_sock=$XDG_RUNTIME_DIR/contained-podman/host/podman.sock
fi
OUT="podman --url unix://$host_sock"
bx() { $OUT exec --user 1000 "$name" "$@"; }
step() { printf '\n=== %s\n' "$*"; }
# probe LABEL HOST:PORT: TCP connect from the box, then an HTTP GET.
probe() {
  rc=0
  bx timeout 5 bash -c "exec 3<>/dev/tcp/${2%:*}/${2##*:}" 2>/dev/null || rc=$?
  case $rc in
    0)
      code=$(bx curl -s -o /dev/null -w '%{http_code}' -m 4 "http://$2/" \
             || true)
      printf 'RESULT %-34s open (http %s)\n' "$1" "$code" ;;
    124) printf 'RESULT %-34s no answer in 5 s\n' "$1" ;;
    *) printf 'RESULT %-34s refused or unreachable\n' "$1" ;;
  esac
}

$OUT container exists "$name" || {
  echo "no running $name; run KEEP=1 .../run.sh first" >&2
  exit 1
}

step "box network setup"
$OUT inspect "$name" --format 'mode={{.HostConfig.NetworkMode}}'
bx ip -4 addr show scope global
bx ip -4 route
bx cat /etc/resolv.conf /etc/hosts
echo "pasta processes on the host:"
pgrep -a pasta || echo none
echo "containers.conf pasta_options of the host service:"
grep -h pasta_options "$HOME"/.local/share/contained-agent/podman/host/containers.conf \
  /etc/containers/containers.conf 2>/dev/null || echo "(none set; Podman defaults)"

step "host listeners"
lo_port=18181
any_port=18182
python3 -m http.server --bind 127.0.0.1 "$lo_port" >/dev/null 2>&1 &
lo_pid=$!
python3 -m http.server --bind 0.0.0.0 "$any_port" >/dev/null 2>&1 &
any_pid=$!
trap 'kill $lo_pid $any_pid 2>/dev/null' EXIT
sleep 1
lan=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
gw=$(bx ip -4 route | sed -n 's/^default via \([0-9.]*\).*/\1/p')
echo "host LAN address: <host-lan> ($lan), box gateway: $gw"

step "probes (host 127.0.0.1:$lo_port, host 0.0.0.0:$any_port)"
probe "box-own-loopback:$lo_port" "127.0.0.1:$lo_port"
probe "host.containers.internal:$lo_port" "host.containers.internal:$lo_port"
probe "host.containers.internal:$any_port" "host.containers.internal:$any_port"
[ -n "$gw" ] && probe "box-gateway:$lo_port" "$gw:$lo_port"
[ -n "$gw" ] && probe "box-gateway:$any_port" "$gw:$any_port"
probe "169.254.1.2:$lo_port" "169.254.1.2:$lo_port"
probe "169.254.1.2:$any_port" "169.254.1.2:$any_port"
probe "host-lan:$lo_port" "$lan:$lo_port"
probe "host-lan:$any_port" "$lan:$any_port"
dport=${PASEO_PROBE##*:}
probe "paseo-daemon via h.c.internal" "host.containers.internal:$dport"
[ -n "$gw" ] && probe "paseo-daemon via gateway" "$gw:$dport"
probe "paseo-daemon via 169.254.1.2" "169.254.1.2:$dport"
[ -n "${LAN_PROBE:-}" ] && probe "other-lan-host" "$LAN_PROBE"
[ -n "${RELAY_PROBE:-}" ] && probe "paseo-relay" "$RELAY_PROBE"
if bx curl -fsS -o /dev/null -m 8 https://example.com/; then
  printf 'RESULT %-34s open\n' "public https"
else
  printf 'RESULT %-34s closed\n' "public https"
fi
