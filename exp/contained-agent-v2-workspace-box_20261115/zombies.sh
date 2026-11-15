#!/bin/sh
# Who leaves the <defunct> pasta processes on the host, and when?
# Prints each zombie's parent, then starts and stops pasta-networked
# containers through the contained-podman service and counts again.
# Read-only apart from those throwaway containers.
set -eu

uid=$(id -u)
if [ -S "/run/contained-podman/$uid/host/podman.sock" ]; then
  host_sock=/run/contained-podman/$uid/host/podman.sock
else
  host_sock=$XDG_RUNTIME_DIR/contained-podman/host/podman.sock
fi
OUT="podman --url unix://$host_sock"
step() { printf '\n=== %s\n' "$*"; }
zombies() { ps -eo pid=,stat=,comm= | awk '$2 ~ /^Z/ && $3 ~ /^pasta/' | wc -l; }

step "zombie pasta processes and their parents"
ps -eo pid,ppid,stat,lstart,comm | awk 'NR == 1 || ($3 ~ /^Z/ && $NF ~ /^pasta/)'
for ppid in $(ps -eo ppid=,stat=,comm= | awk '$2 ~ /^Z/ && $3 ~ /^pasta/ {print $1}' | sort -u); do
  printf '\nparent %s: ' "$ppid"
  ps -o user=,lstart=,args= -p "$ppid" || echo gone
  printf 'its parent: '
  ps -o pid=,args= -p "$(ps -o ppid= -p "$ppid" | tr -d ' ')" || true
  printf 'live children: '
  ps -o pid=,stat=,comm= --ppid "$ppid" | awk '$2 !~ /^Z/' | tr '\n' ' '
  echo
done

step "service process tree"
pid=$(pgrep -u "$uid" -f 'podman --remote=false system service' | head -1 || true)
echo "podman service pid: ${pid:-not found}"
[ -n "$pid" ] && ps -o pid,ppid,args -p "$pid"
[ -n "$pid" ] && ps -o pid,ppid,args -p "$(ps -o ppid= -p "$pid" | tr -d ' ')"
podman --version

step "reproduce: 3 short pasta containers through the service"
image=$($OUT images --format '{{.Repository}}@{{.Digest}}' quay.io/podman/stable | head -1)
before=$(zombies)
for i in 1 2 3; do
  $OUT run --rm --entrypoint=/bin/true "$image"
done
sleep 2
after=$(zombies)
echo "zombie pasta: before=$before after=$after"
ps -eo pid,ppid,stat,comm | awk '$3 ~ /^Z/ && $4 ~ /^pasta/' | tail -3

step "same with --network=none (no pasta expected)"
before=$(zombies)
$OUT run --rm --network=none --entrypoint=/bin/true "$image"
sleep 2
echo "zombie pasta: before=$before after=$(zombies)"
