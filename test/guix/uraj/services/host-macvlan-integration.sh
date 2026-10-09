#!/bin/sh
# Run inside: unshare -Urnmpf --mount-proc sh test/guix/uraj/services/host-macvlan-integration.sh
# PATH needs iproute2; HOST_MACVLAN_START is built with parent "macvlan-test".
set -eu
: "${HOST_MACVLAN_START:?Set the built test launcher}"
ip link add macvlan-test type dummy
ip link set macvlan-test up
for attempt in 1 2; do
    "$HOST_MACVLAN_START"
    ip -o link show host0 | grep -q '02:31:00:00:00:02'
    ip -d link show host0 | grep -q 'macvlan mode bridge'
    test -z "$(ip -4 -o address show host0)"
    test -z "$(ip route show dev host0)"
    ip address add 192.0.2.5/24 dev host0
    ip route add default via 192.0.2.1 dev host0
    before=$(ip -j -4 address show host0)
    routes=$(ip route show dev host0)
    if "$HOST_MACVLAN_START"; then exit 1; fi
    test "$before" = "$(ip -j -4 address show host0)"
    test "$routes" = "$(ip route show dev host0)"
    ip link show host0 >/dev/null
    ip link delete host0
done
ip link delete macvlan-test
