#!/usr/bin/env bash
# Tests gateway/nftables/nftables.conf: loads it in a namespace with the interfaces of gw-vpn
# and connects through it from namespaces for the untrusted segment, the LAN with k8s-node,
# the management network with the CA, and the tunnel, which holds the addresses of every role.
# Run with sudo in the host network namespace, where nf_log_all_netns can be set to log the
# drops of a namespace. Requires socat.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONF=$ROOT/gateway/nftables/nftables.conf
NAMESPACES="gw internet lan management tunnel"
LISTENERS=()
FAILED=0

run() {
    local description=$1 output line
    shift
    if output=$("$@" 2>&1); then
        echo "ok    $description"
    else
        echo "FAIL  $description"
        while IFS= read -r line; do echo "      $line"; done <<< "$output"
        FAILED=1
    fi
}

ns() { ip netns exec "nft-$1" "${@:2}"; }

cleanup() {
    local name
    [[ ${#LISTENERS[@]} == 0 ]] || kill "${LISTENERS[@]}" 2> /dev/null
    for name in $NAMESPACES; do ip netns delete "nft-$name" 2> /dev/null; done
    [[ -z $LOG_ALL_NETNS ]] || sysctl -qw net.netfilter.nf_log_all_netns="$LOG_ALL_NETNS"
}

# link NS1 INTERFACE1 ADDRESS1 NS2 ADDRESS2: a cable between NS1 and the eth0 of NS2.
link() {
    ip -n "nft-$1" link add "$2" type veth peer name eth0 netns "nft-$4"
    ns "$1" ip address add "$3" dev "$2"
    ns "$1" ip link set "$2" up
    ns "$4" ip address add "$5" dev eth0
    ns "$4" ip link set eth0 up
}

# listen NS PROTOCOL ADDRESS PORT: a server that answers each client with its source address.
# Called without ns, so that $! is the socat that cleanup kills.
listen() {
    local server=TCP4-LISTEN:$4,reuseaddr
    [[ $2 == tcp ]] || server=UDP4-RECVFROM:$4
    # shellcheck disable=SC2016 # the server expands SOCAT_PEERADDR, not this shell
    ip netns exec "nft-$1" socat "$server,bind=$3,fork" SYSTEM:'echo $SOCAT_PEERADDR' 2> /dev/null &
    LISTENERS+=("$!")
}

# reaches NS SOURCE DESTINATION PROTOCOL PORT: prints the answer, or fails after a second.
# Only an answer counts: socat ignores dropped UDP packets.
reaches() {
    local answer
    answer=$(ns "$1" socat -T1 -t1 - "$4:$3:$5,bind=$2,connect-timeout=1" <<< probe) || return 1
    [[ -n $answer ]] || { echo "no answer"; return 1; }
    echo "$answer"
}
blocked() { ! reaches "$@"; }

# seen_as ADDRESS NS SOURCE DESTINATION PROTOCOL PORT: answered, and the server saw ADDRESS.
seen_as() {
    local seen
    seen=$(reaches "${@:2}") || return 1
    echo "seen as $seen"
    [[ $seen == "$1" ]]
}

# logged PATTERN: a line of the kernel log written during this run matches PATTERN.
logged() {
    dmesg | sed -n "\|$MARKER|,\$p" | grep -E "$1" || { echo "No kernel log line matches $1"; return 1; }
}

LOG_ALL_NETNS=$(sysctl -n net.netfilter.nf_log_all_netns)
MARKER="tests/nftables.sh $$ $(date +%s%N)"
trap cleanup EXIT
sysctl -qw net.netfilter.nf_log_all_netns=1
echo "$MARKER" > /dev/kmsg
for name in $NAMESPACES; do
    ip netns add "nft-$name"
    ns "$name" ip link set lo up
done
link gw eth0 203.0.113.10/24 internet 203.0.113.51/24
link gw eth1 10.10.0.1/16 lan 10.10.10.5/16
link gw eth2 192.168.100.1/24 management 192.168.100.20/24
link gw tun0 10.8.0.1/24 tunnel 10.8.0.10/24
ns gw sysctl -qw net.ipv4.ip_forward=1
# OpenVPN routes the branch LAN to gw-sucursal (route and iroute).
ns gw ip route add 172.16.20.0/24 via 10.8.0.30
ns tunnel ip address add 10.8.0.20/24 dev eth0
ns tunnel ip address add 10.8.0.30/24 dev eth0
ns tunnel ip address add 172.16.20.10/32 dev lo
ns tunnel ip route add 10.10.0.0/16 via 10.8.0.1
ns tunnel ip route add 192.168.100.0/24 via 10.8.0.1
# CU1: a manual route to the LAN through the gateway.
ns internet ip route add 10.10.0.0/16 via 203.0.113.10
ns management ip route add 10.10.0.0/16 via 192.168.100.1
# Lets the LAN try connections into the tunnel; seen_as checks the SNAT.
ns lan ip route add 10.8.0.0/24 via 10.10.0.1

run "Has flush ruleset" grep -q "^flush ruleset" "$CONF"
run "The ruleset loads on a gateway with eth0, eth1, eth2 and tun0" ns gw nft --file "$CONF"

for port in 22 80 6443; do listen lan tcp 10.10.10.5 "$port"; done
listen gw tcp 0.0.0.0 22
listen gw udp 10.8.0.1 53
# Every address: only the ruleset limits DNS to 10.8.0.1.
listen gw tcp 0.0.0.0 53
listen gw udp 203.0.113.10 1194
listen management tcp 192.168.100.20 22
listen tunnel tcp 10.8.0.10 8000
sleep 1

# Controls for the blocked checks: these servers answer the gateway.
run "The gateway reaches the management network" reaches gw 192.168.100.1 192.168.100.20 tcp 22
run "The gateway reaches dev through the tunnel" reaches gw 10.8.0.1 10.8.0.10 tcp 8000

# CU1: default deny from the untrusted segment.
run "Untrusted segment reaches OpenVPN on UDP 1194" reaches internet 203.0.113.51 203.0.113.10 udp 1194
run "Untrusted segment cannot reach SSH on the gateway" blocked internet 203.0.113.51 203.0.113.10 tcp 22
for port in 80 22 6443; do
    run "Untrusted segment cannot reach the node on $port, even with a route" \
        blocked internet 203.0.113.51 10.10.10.5 tcp "$port"
done

# CU3: dev (10.8.0.10-.19) only reaches the Ingress and dnsmasq.
run "dev reaches the Ingress, which sees the SNAT address 10.10.0.1" \
    seen_as 10.10.0.1 tunnel 10.8.0.10 10.10.10.5 tcp 80
run "dev cannot reach the API server" blocked tunnel 10.8.0.10 10.10.10.5 tcp 6443
run "dev cannot reach SSH on the node" blocked tunnel 10.8.0.10 10.10.10.5 tcp 22
run "dev reaches dnsmasq on UDP 53" reaches tunnel 10.8.0.10 10.8.0.1 udp 53
run "dev reaches dnsmasq on TCP 53" reaches tunnel 10.8.0.10 10.8.0.1 tcp 53
run "dev cannot reach port 53 on the LAN address of the gateway" blocked tunnel 10.8.0.10 10.10.0.1 tcp 53
run "dev cannot reach SSH on the gateway" blocked tunnel 10.8.0.10 10.8.0.1 tcp 22
run "dev cannot reach the management network" blocked tunnel 10.8.0.10 192.168.100.20 tcp 22

# CU3: sysadmin (10.8.0.20-.29) also reaches SSH and the API server on the node.
for port in 80 22 6443; do
    run "sysadmin reaches the node on $port" seen_as 10.10.0.1 tunnel 10.8.0.20 10.10.10.5 tcp "$port"
done
run "sysadmin cannot reach SSH on the gateway" blocked tunnel 10.8.0.20 10.8.0.1 tcp 22

# CU6: the branch LAN behind gw-sucursal (10.8.0.30) only reaches the Ingress.
run "Branch host reaches the Ingress" seen_as 10.10.0.1 tunnel 172.16.20.10 10.10.10.5 tcp 80
run "Branch host cannot reach the API server" blocked tunnel 172.16.20.10 10.10.10.5 tcp 6443
run "Branch host cannot reach SSH on the node" blocked tunnel 172.16.20.10 10.10.10.5 tcp 22
run "gw-sucursal reaches dnsmasq to forward the branch queries" reaches tunnel 10.8.0.30 10.8.0.1 udp 53

# Management network and LAN.
run "Management network reaches SSH on the gateway" reaches management 192.168.100.20 192.168.100.1 tcp 22
run "Management network is not routed to the node" blocked management 192.168.100.20 10.10.10.5 tcp 22
run "LAN cannot open connections into the tunnel" blocked lan 10.10.10.5 10.8.0.10 tcp 8000
run "LAN cannot reach SSH on the gateway" blocked lan 10.10.10.5 10.10.0.1 tcp 22

run "The input chain logs SSH from the untrusted segment" \
    logged 'the-store input drop: IN=eth0 .*SRC=203\.0\.113\.51 DST=203\.0\.113\.10 .*DPT=22 '
run "The forward chain logs dev trying the API server" \
    logged 'the-store forward drop: IN=tun0 OUT=eth1 .*SRC=10\.8\.0\.10 DST=10\.10\.10\.5 .*DPT=6443 '

exit "$FAILED"
