#!/usr/bin/env bash
# Tests the site-to-site access of the branch (CU6): runs gw-vpn and gw-sucursal in network
# namespaces with their configurations, the gateway bundle and the gw-sucursal profile of
# scripts/pki.sh, and connects from host-suc, which has no VPN client, to the node.
# Run with sudo; requires EasyRSA 3, OpenVPN, nftables, dnsmasq, dig, socat, tcpdump and netplan.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BRANCH=$ROOT/branch
NAMESPACES="gw suc host node"
MARKER=the-store-branch-probe-$$   # payload of the probes, looked for in the captures
PIDS=()
CAPTURES=()
WORK=
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

ns() { ip netns exec "branch-$1" "${@:2}"; }

cleanup() {
    local pid name
    [[ $FAILED == 0 ]] || tail -n 15 "$WORK"/*.log
    for pid in "${PIDS[@]}" $(cat "$WORK"/*.pid 2> /dev/null); do
        kill "$pid" 2> /dev/null
        while kill -0 "$pid" 2> /dev/null; do sleep 0.2; done
    done
    for name in $NAMESPACES; do ip netns delete "branch-$name" 2> /dev/null; done
    rm -rf "$WORK"
}

# link NS1 INTERFACE1 ADDRESS1 NS2 ADDRESS2: a cable between NS1 and the eth0 of NS2.
link() {
    ip -n "branch-$1" link add "$2" type veth peer name eth0 netns "branch-$4"
    ns "$1" ip address add "$3" dev "$2"
    ns "$1" ip link set "$2" up
    ns "$4" ip address add "$5" dev eth0
    ns "$4" ip link set eth0 up
}

# listen NS ADDRESS PORT: a TCP server that answers each client with its source address.
listen() {
    # shellcheck disable=SC2016 # the server expands SOCAT_PEERADDR, not this shell
    ip netns exec "branch-$1" socat "TCP4-LISTEN:$3,reuseaddr,bind=$2,fork" SYSTEM:'echo $SOCAT_PEERADDR' 2> /dev/null &
    PIDS+=("$!")
}

# reaches NS SOURCE DESTINATION PORT: sends MARKER over TCP and prints the answer, or fails
# after two seconds.
reaches() {
    local answer
    answer=$(ns "$1" socat -T2 -t2 - "TCP4:$3:$4,bind=$2,connect-timeout=2" <<< "$MARKER") || return 1
    [[ -n $answer ]] || { echo "no answer"; return 1; }
    echo "$answer"
}
blocked() { ! reaches "$@"; }

# seen_as ADDRESS NS SOURCE DESTINATION PORT: answered, and the server saw ADDRESS.
seen_as() {
    local seen
    seen=$(reaches "${@:2}") || return 1
    echo "seen as $seen"
    [[ $seen == "$1" ]]
}

pki() { env EASYRSA_PASSOUT=pass:test EASYRSA_PASSIN=pass:test bash "$ROOT/scripts/pki.sh" "$WORK/ca" "$@"; }

wait_for() { timeout 10 bash -c 'until grep -q "$0" "$1" 2>/dev/null; do sleep 0.2; done' "$1" "$2"; }

issue_certificates() {
    pki init && pki issue-server && pki issue-client gw-sucursal sucursal 30 &&
        pki export-server "$WORK/bundle" && pki export-client gw-sucursal "$WORK/gw-sucursal.ovpn"
}

forwarding_enabled() {
    ns suc sysctl -p "$BRANCH/sysctl/the-store.conf" && [[ $(ns suc sysctl -n net.ipv4.ip_forward) == 1 ]]
}

# netplan renders the host-suc file with its address, gateway and DNS server.
netplan_configures_host_suc() {
    local root=$WORK/netplan network
    install -D -m 600 "$BRANCH/host-suc/netplan.yaml" "$root/etc/netplan/90-the-store.yaml" &&
        netplan generate --root-dir "$root" || return 1
    network=$(cat "$root"/run/systemd/network/*eth0.network)
    echo "$network"
    grep -qx 'Address=172.16.20.10/24' <<< "$network" && grep -qx 'Gateway=172.16.20.1' <<< "$network" &&
        grep -qx 'DNS=172.16.20.1' <<< "$network"
}

start_dnsmasq() {
    ip netns exec "branch-$1" dnsmasq --conf-file="$2" --keep-in-foreground --pid-file= \
        --user=nobody --group=nogroup 2> "$WORK/dnsmasq-$1.log" &
    PIDS+=("$!")
}

start_gw_vpn() {
    # WORK/bundle and WORK/run stand in for /etc/openvpn/server/the-store and /run/openvpn-server.
    mkdir -p "$WORK/run"
    sed -e "s#/etc/openvpn/server/the-store#$WORK/bundle#" -e "s#/run/openvpn-server#$WORK/run#" \
        "$ROOT/gateway/openvpn/server.conf" > "$WORK/bundle/server.conf"
    chmod 755 "$WORK"   # the nobody user must enter WORK
    ns gw openvpn --config "$WORK/bundle/server.conf" --verb 4 --disable-dco --daemon --log "$WORK/gw-vpn.log" \
        --writepid "$WORK/gw-vpn.pid" &&
        wait_for "Initialization Sequence Completed" "$WORK/gw-vpn.log"
}

# gw-sucursal uses the profile of export-client, as /etc/openvpn/client/the-store.conf.
connect_gw_sucursal() {
    ns suc openvpn --config "$WORK/gw-sucursal.ovpn" --disable-dco --daemon --log "$WORK/gw-sucursal.log" \
        --writepid "$WORK/gw-sucursal.pid" &&
        wait_for "Initialization Sequence Completed" "$WORK/gw-sucursal.log" &&
        ns suc ip -4 address show dev tun0 | grep -q "inet 10\.8\.0\.30/24"
}

routes_branch_to_tunnel() {
    local route
    route=$(ns gw ip -4 route show 172.16.20.0/24)
    echo "$route"
    grep -q "dev tun0" <<< "$route"
}

resolves_to_node() {
    local answer
    answer=$(ns host dig @172.16.20.1 +short +time=2 +tries=1 "$1" A)
    echo "$1 -> ${answer:-no answer}"
    [[ $answer == 10.10.10.5 ]]
}

answers_status() {
    local status
    status=$(ns host dig @172.16.20.1 +time=2 +tries=1 "$1" A | grep -o 'status: [A-Z]*')
    echo "$1 -> ${status:-no answer}"
    [[ $status == "status: $2" ]]
}

# capture NS INTERFACE FILE: IPv4 packets only; the veth links also carry IPv6 announcements.
capture() {
    ip netns exec "branch-$1" tcpdump -i "$2" -n -U -Z root -w "$3" ip 2> /dev/null &
    CAPTURES+=("$!")
    PIDS+=("$!")
}

stop_captures() {
    sleep 0.5
    kill -INT "${CAPTURES[@]}"
    wait "${CAPTURES[@]}"
}

# only_tunnel_packets FILE: every packet is UDP between gw-sucursal and port 1194 of gw-vpn,
# and none carries MARKER in clear.
only_tunnel_packets() {
    local packets others
    packets=$(tcpdump -n -r "$1" 2> /dev/null)
    head -n 5 <<< "$packets"
    [[ -n $packets ]] || { echo "No packet captured"; return 1; }
    others=$(grep -vE ' IP (203\.0\.113\.20\.[0-9]+ > 203\.0\.113\.10\.1194|203\.0\.113\.10\.1194 > 203\.0\.113\.20\.[0-9]+): UDP' <<< "$packets")
    [[ -z $others ]] || { echo "Other packets:"; echo "$others"; return 1; }
    ! grep -qaF "$MARKER" "$1" || { echo "The probe is in clear"; return 1; }
}

# clear_from_host_suc FILE: the probe of host-suc, in clear and with its own address.
clear_from_host_suc() {
    local packets
    packets=$(tcpdump -n -A -r "$1" 2> /dev/null)
    grep -E ' IP 172\.16\.20\.10\.[0-9]+ > 10\.10\.10\.5\.80: ' <<< "$packets" | head -n 3
    grep -qE ' IP 172\.16\.20\.10\.[0-9]+ > 10\.10\.10\.5\.80: ' <<< "$packets" && grep -qF "$MARKER" <<< "$packets"
}

WORK=$(mktemp -d)
trap cleanup EXIT
for name in $NAMESPACES; do
    ip netns add "branch-$name"
    ns "$name" ip link set lo up
done
link gw eth0 203.0.113.10/24 suc 203.0.113.20/24
link gw eth1 10.10.0.1/16 node 10.10.10.5/16
link suc eth1 172.16.20.1/24 host 172.16.20.10/24
ns gw sysctl -qw net.ipv4.ip_forward=1
# Same as branch/host-suc/netplan.yaml. The node has no route back: gw-vpn uses SNAT.
ns host ip route add default via 172.16.20.1

run "The sysctl file enables forwarding on gw-sucursal" forwarding_enabled
run "netplan gives host-suc its address, and gw-sucursal as gateway and DNS server" netplan_configures_host_suc
run "The gw-vpn ruleset loads" ns gw nft --file "$ROOT/gateway/nftables/nftables.conf"
run "The gw-sucursal ruleset loads" ns suc nft --file "$BRANCH/nftables/nftables.conf"
run "The gw-sucursal dnsmasq configuration is valid" dnsmasq --test --conf-file="$BRANCH/dnsmasq/the-store.conf"
run "pki.sh issues the gw-sucursal certificate and exports its profile" issue_certificates
run "gw-vpn starts" start_gw_vpn
run "gw-sucursal opens the tunnel and gets 10.8.0.30" connect_gw_sucursal
start_dnsmasq gw "$ROOT/gateway/dnsmasq/the-store.conf"
start_dnsmasq suc "$BRANCH/dnsmasq/the-store.conf"
for port in 22 80 6443; do listen node 10.10.10.5 "$port"; done
listen suc 0.0.0.0 22
sleep 1

run "gw-vpn assigns 10.8.0.30 to gw-sucursal from its CCD" \
    grep -q "MULTI: Learn: 10.8.0.30 -> gw-sucursal/" "$WORK/gw-vpn.log"
run "gw-vpn learns the branch LAN from the iroute of gw-sucursal" \
    grep -q "MULTI: internal route 172.16.20.0/24 -> gw-sucursal/" "$WORK/gw-vpn.log"
run "gw-vpn routes the branch LAN to the tunnel" routes_branch_to_tunnel

for service in ui catalog carts orders checkout; do
    run "host-suc resolves $service.the-store.internal through gw-sucursal" \
        resolves_to_node "$service.the-store.internal"
done
run "host-suc gets REFUSED for other names" answers_status example.com REFUSED

capture suc eth0 "$WORK/wan.pcap"
capture gw tun0 "$WORK/tunnel.pcap"
sleep 1
run "host-suc reaches the Ingress, which sees the SNAT address 10.10.0.1" \
    seen_as 10.10.0.1 host 172.16.20.10 10.10.10.5 80
stop_captures
run "Between the gateways there is only OpenVPN on UDP 1194, without the request in clear" \
    only_tunnel_packets "$WORK/wan.pcap"
run "gw-vpn gets the request in clear from 172.16.20.10: gw-sucursal does no NAT" \
    clear_from_host_suc "$WORK/tunnel.pcap"
run "host-suc cannot reach SSH on the node" blocked host 172.16.20.10 10.10.10.5 22
run "host-suc cannot reach the API server" blocked host 172.16.20.10 10.10.10.5 6443

# Packets sent by gw-sucursal itself skip its forward chain: gw-vpn still filters the branch.
run "Without the gw-sucursal rules, gw-vpn accepts the branch on the Ingress" \
    seen_as 10.10.0.1 suc 172.16.20.1 10.10.10.5 80
run "Without the gw-sucursal rules, gw-vpn refuses SSH from the branch" blocked suc 172.16.20.1 10.10.10.5 22
run "Without the gw-sucursal rules, gw-vpn refuses the API server from the branch" \
    blocked suc 172.16.20.1 10.10.10.5 6443

# No incoming port on gw-sucursal, although a server listens on every address.
run "The SSH server of gw-sucursal answers locally" reaches suc 127.0.0.1 127.0.0.1 22
run "gw-sucursal exposes no port on the untrusted segment" blocked gw 203.0.113.10 203.0.113.20 22
run "host-suc cannot reach SSH on gw-sucursal" blocked host 172.16.20.10 172.16.20.1 22

exit "$FAILED"
