#!/usr/bin/env bash
# Tests gateway/openvpn/server.conf by running it with the bundle of scripts/pki.sh and real
# clients (CU1, CU4, CU5). Run with sudo; requires EasyRSA 3, ping, socat, tcpdump, ss and setpriv.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONF=$ROOT/gateway/openvpn/server.conf
FAILED=0
MANAGEMENT_SOCKET=/run/openvpn-server/the-store.sock

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

# Real server and clients, using the bundle from scripts/pki.sh. Needs EasyRSA 3.
WORK=
GATEWAY_IP=203.0.113.10   # remote of clients/client.conf
DEV_NS=the-store-dev      # network namespace of dev-01
INGRESS_IP=10.10.10.5     # the node is the gateway itself here, so requests end at tun0
MARKER=the-store-probe-$$ # payload of the request, looked for in the captures

cleanup() {
    local pid
    [[ $FAILED == 0 ]] || tail -n 15 "$WORK"/*.log
    for pid in $(cat "$WORK"/*.pid 2>/dev/null); do
        kill "$pid" 2>/dev/null
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    done
    ip netns delete "$DEV_NS" 2>/dev/null
    ip addr del "$GATEWAY_IP/32" dev lo 2>/dev/null
    ip addr del "$INGRESS_IP/32" dev lo 2>/dev/null
    rm -rf "$WORK"
}

pki() { env EASYRSA_PASSOUT=pass:test EASYRSA_PASSIN=pass:test bash "$ROOT/scripts/pki.sh" "$WORK/ca" "$@"; }

wait_for() { timeout 10 bash -c 'until grep -q "$0" "$1" 2>/dev/null; do sleep 0.2; done' "$1" "$2"; }

issue_certificates() {
    local client
    pki init && pki issue-server &&
        pki issue-client dev-01 dev 10 && pki issue-client admin-01 sysadmin 20 &&
        pki export-server "$WORK/bundle" &&
        pki issue-client rogue dev 11 || return 1   # after the export: no CCD file in the bundle
    for client in dev-01 admin-01 rogue; do
        pki export-client "$client" "$WORK/$client.ovpn" || return 1
    done
}

start_server() {
    # WORK/bundle stands in for /etc/openvpn/server/the-store; the nobody user must enter WORK.
    sed "s#/etc/openvpn/server/the-store#$WORK/bundle#" "$CONF" > "$WORK/bundle/server.conf"
    chmod 755 "$WORK"
    mkdir -p /run/openvpn-server
    openvpn --config "$WORK/bundle/server.conf" --verb 4 --disable-dco --daemon --log "$WORK/server.log" \
        --writepid "$WORK/server.pid" &&
        wait_for "Initialization Sequence Completed" "$WORK/server.log" &&
        ip -4 addr show dev tun0 | grep -q "inet 10\.8\.0\.1/24"
}

# dev-01 connects from its own namespace on the untrusted segment.
connect_dev_01() {
    ip netns add "$DEV_NS" &&
        ip link add the-store-wan type veth peer name eth0 netns "$DEV_NS" &&
        ip addr add 203.0.113.1/24 dev the-store-wan && ip link set the-store-wan up &&
        ip -n "$DEV_NS" addr add 203.0.113.50/24 dev eth0 && ip -n "$DEV_NS" link set eth0 up &&
        ip netns exec "$DEV_NS" openvpn --config "$WORK/dev-01.ovpn" --disable-dco --daemon --log "$WORK/dev-01.log" \
            --writepid "$WORK/dev-01.pid" &&
        wait_for "Initialization Sequence Completed" "$WORK/dev-01.log"
}

# Not on every address, not on IPv6.
listens_only_on_the_gateway_address() {
    local sockets
    sockets=$(ss -H -uln | awk '$4 ~ /:1194$/ { print $4 }')
    echo "UDP sockets on port 1194: ${sockets:-none}"
    [[ $sockets == "$GATEWAY_IP:1194" ]]
}

runs_as_nobody() {
    local user
    user=$(ps -o user= -p "$(cat "$WORK/server.pid")")
    echo "user: $user"
    [[ $user == nobody ]]
}

# The address dev-01 got from its CCD, with the /24 of the pool.
has_tunnel_address() {
    ip -n "$DEV_NS" -4 address show dev tun0 | grep -q "inet ${1//./\\.}/24"
}

negotiated_crypto() {
    grep -E "TLSv1\.3|Data Channel: .*AES-256-GCM" "$WORK/dev-01.log"
    grep -q "TLSv1\.3" "$WORK/dev-01.log" && grep -q "Data Channel: .*AES-256-GCM" "$WORK/dev-01.log"
}

# rejects_client_with OPTION...: admin-01 with OPTION... does not connect in 8 seconds.
rejects_client_with() {
    timeout 8 openvpn --config "$WORK/admin-01.ovpn" --dev tun13 --disable-dco --route-noexec \
        --ifconfig-noexec --script-security 0 "$@" > "$WORK/rejected.log" 2>&1
    tail -n 3 "$WORK/rejected.log"
    grep -q "OpenVPN 2\." "$WORK/rejected.log" && ! grep -q "Options error" "$WORK/rejected.log" &&
        ! grep -q "Initialization Sequence Completed" "$WORK/rejected.log"
}

# The PUSH_REPLY to dev-01: zone DNS, address, keepalive and the route to the node, nothing else.
pushed_to_dev_01() {
    local push option
    push=$(grep -o "SENT CONTROL \[dev-01\]: 'PUSH_REPLY,[^']*'" "$WORK/server.log" | tail -n 1)
    echo "$push"
    [[ -n $push ]] || return 1
    for option in "dns server 0 address 10.8.0.1" "dns server 0 resolve-domains the-store.internal" \
            "route 10.10.10.5 255.255.255.255" "ifconfig 10.8.0.10 255.255.255.0" "ping 10," "ping-restart 120"; do
        grep -qF ",$option" <<< "$push" || { echo "Missing: $option"; return 1; }
    done
    ! grep -qE "redirect-gateway|dhcp-option|search-domains|172\.16\.20" <<< "$push" || { echo "Unexpected option"; return 1; }
}

# tun0 carries only its subnet and the node.
routes_only_the_node() {
    local routes
    routes=$(ip -n "$DEV_NS" -4 route show dev tun0)
    echo "$routes"
    grep -q "^10\.10\.10\.5 via 10\.8\.0\.1" <<< "$routes" && [[ $(wc -l <<< "$routes") == 2 ]]
}

# spoofed_source_dropped ADDRESS: dev-01 sends from ADDRESS, and the server drops it.
spoofed_source_dropped() {
    ip -n "$DEV_NS" addr add "$1/32" dev tun0 &&
        ! ip netns exec "$DEV_NS" ping -c 1 -W 1 -I "$1" 10.8.0.1 &&
        wait_for "bad source address from client \[$1\], packet dropped" "$WORK/server.log"
}

# capture INTERFACE FILE: IPv4 only (the veth links carry IPv6 announcements). --immediate-mode:
# otherwise the kernel batches the packets and the INT right after the request loses them.
capture() {
    tcpdump -i "$1" -n -U --immediate-mode -Z root -w "$2" ip 2> /dev/null &
    echo "$!" > "$WORK/tcpdump-$1.pid"
}

stop_captures() {
    local pids
    sleep 0.5
    pids=$(cat "$WORK"/tcpdump-*.pid)
    # shellcheck disable=SC2086 # one word per pid
    kill -INT $pids && wait $pids
    rm "$WORK"/tcpdump-*.pid
}

# reaches_ingress: dev-01 sends MARKER to the Ingress through the tunnel and gets the answer.
reaches_ingress() {
    local answer
    answer=$(ip netns exec "$DEV_NS" socat -T2 -t2 - "TCP4:$INGRESS_IP:80,connect-timeout=2" <<< "$MARKER") || return 1
    echo "answer: $answer"
    [[ $answer == ok ]]
}

# only_openvpn_packets FILE: every packet is UDP between dev-01 and port 1194 of the gateway,
# and none carries MARKER in clear.
only_openvpn_packets() {
    local packets others
    packets=$(tcpdump -n -r "$1" 2> /dev/null)
    head -n 5 <<< "$packets"
    [[ -n $packets ]] || { echo "No packet captured"; return 1; }
    others=$(grep -vE " IP (203\.0\.113\.50\.[0-9]+ > $GATEWAY_IP\.1194|$GATEWAY_IP\.1194 > 203\.0\.113\.50\.[0-9]+): UDP" <<< "$packets")
    [[ -z $others ]] || { echo "Other packets:"; echo "$others"; return 1; }
    ! grep -qaF "$MARKER" "$1" || { echo "The request is in clear"; return 1; }
}

# clear_in_tunnel FILE: the request of dev-01 to the Ingress, in clear once the gateway decrypts it.
clear_in_tunnel() {
    local packets
    packets=$(tcpdump -n -A -r "$1" 2> /dev/null)
    head -n 3 <<< "$packets"
    grep -qE " IP 10\.8\.0\.10\.[0-9]+ > $INGRESS_IP\.80: " <<< "$packets" && grep -qF "$MARKER" <<< "$packets"
}

# reply_size PORT: bytes that PORT of the gateway answers to the first packet of an OpenVPN client
# (P_CONTROL_HARD_RESET_CLIENT_V2) sent without the tls-crypt key; a server without tls-crypt
# answers 26 (checked by hand). Fails on an ICMP error.
reply_size() {
    printf '\x38\x01\x02\x03\x04\x05\x06\x07\x08\x00\x00\x00\x00\x00' |
        ip netns exec "$DEV_NS" socat -T2 -t2 - "UDP4:$GATEWAY_IP:$1" | wc -c
}

# Silent, like a filtered port: no answer and no ICMP error, so a UDP scan learns nothing.
unanswered() { local size; size=$(reply_size "$1") && [[ $size == 0 ]]; }
answered() { local size; size=$(reply_size "$1") && (( size > 0 )); }

# cleanup deletes this address, so it must not be one that was already there (a running cluster).
[[ $(ip -4 addr show dev lo) != *" $INGRESS_IP/"* ]] || { echo "$INGRESS_IP is already on lo"; exit 1; }
WORK=$(mktemp -d)
trap cleanup EXIT
ip addr add "$GATEWAY_IP/32" dev lo
ip addr add "$INGRESS_IP/32" dev lo
run "pki.sh issues the certificates and exports the gateway bundle" issue_certificates
run "OpenVPN server starts with the bundle (tun0 is 10.8.0.1/24)" start_server
run "OpenVPN listens only on UDP 203.0.113.10:1194, over IPv4" listens_only_on_the_gateway_address
run "OpenVPN gives up root and runs as nobody" runs_as_nobody
run "dev-01 connects from the untrusted segment" connect_dev_01

# rogue has a valid certificate, but the bundle has no CCD file for it.
rogue_rejected() {
    openvpn --config "$WORK/rogue.ovpn" --dev tun11 --daemon --log "$WORK/rogue.log" \
        --writepid "$WORK/rogue.pid" --route-noexec --ifconfig-noexec --script-security 0 &&
        wait_for "authentication failed for common name 'rogue'" "$WORK/server.log" ||
        { echo "The server did not reject rogue"; return 1; }
}

run "The server log shows the verification of the dev-01 certificate" \
    grep -q "VERIFY OK: depth=0, CN=dev-01" "$WORK/server.log"
run "dev-01 negotiated TLS 1.3 and AES-256-GCM" negotiated_crypto
run "dev-01 gets its fixed IP 10.8.0.10/24 from its CCD" has_tunnel_address 10.8.0.10
run "The server pushes dev-01 the zone DNS, the keepalive and only the route to the node" pushed_to_dev_01
run "A valid certificate without a CCD file is rejected (ccd-exclusive)" rogue_rejected
run "dev-01 routes only the node 10.10.10.5 through the tunnel (split tunnel)" routes_only_the_node
run "dev-01 cannot send with the sysadmin address 10.8.0.20" spoofed_source_dropped 10.8.0.20
run "A client limited to TLS 1.2 is rejected" rejects_client_with --tls-version-min 1.2 --tls-version-max 1.2
run "A client that only offers AES-128-GCM is rejected" rejects_client_with --data-ciphers AES-128-GCM

# CU5: the Ingress answers on the node address.
socat "TCP4-LISTEN:80,bind=$INGRESS_IP,reuseaddr,fork" SYSTEM:'echo ok' 2> /dev/null &
echo "$!" > "$WORK/ingress.pid"
capture the-store-wan "$WORK/wan.pcap"
capture tun0 "$WORK/tunnel.pcap"
sleep 1
run "dev-01 reaches the Ingress through the tunnel" reaches_ingress
stop_captures
run "On the untrusted segment the request is only OpenVPN on UDP 1194, not in clear" \
    only_openvpn_packets "$WORK/wan.pcap"
run "On tun0 of the gateway the request arrives in clear from 10.8.0.10" clear_in_tunnel "$WORK/tunnel.pcap"

# CU1: a scan of UDP 1194 learns nothing, and the same probe does get an answer from the control server.
socat "UDP4-RECVFROM:1196,bind=$GATEWAY_IP,fork" SYSTEM:'echo pong' 2> /dev/null &
echo "$!" > "$WORK/control.pid"
run "OpenVPN gives no answer to a handshake without the tls-crypt key" unanswered 1194
run "A UDP server on another port does answer the same packet (control)" answered 1196

# Revocation (CU4): a second user stays connected while dev-01 is revoked.
CRL=$WORK/ca/pki/crl.pem

# Same as in update-crl.sh: quit only after the response, which OpenVPN drops when it closes.
management() {
    local line pid
    coproc SOCKET { socat - "UNIX-CONNECT:$MANAGEMENT_SOCKET"; }
    pid=$SOCKET_PID
    printf '%s\n' "$1" >&"${SOCKET[1]}"
    while IFS= read -r -t 5 line <&"${SOCKET[0]}"; do
        line=${line%$'\r'}
        echo "$line"
        [[ $line == SUCCESS:* || $line == ERROR:* || $line == END ]] && break
    done
    printf 'quit\n' >&"${SOCKET[1]}"
    wait "$pid"
}

# Not grep -q: management must read the whole response and quit, since the interface takes one
# client at a time.
connected() { management "status 2" | grep "^CLIENT_LIST,$1," > /dev/null; }

both_connected() { connected dev-01 && connected admin-01; }

disconnected() {
    local attempt
    for attempt in {1..50}; do
        connected "$1" || return 0
        sleep 0.2
    done
    return 1
}

# update_crl CRL_FILE [NAME...]: update-crl reads the CRL from standard input, as over ssh.
update_crl() {
    local crl=$1
    shift
    BUNDLE_DIR=$WORK/bundle bash "$ROOT/gateway/openvpn/update-crl.sh" "$@" < "$crl"
}

# refuses_crl MESSAGE ARGUMENT...: update-crl fails and prints MESSAGE, so it refused for that reason.
refuses_crl() {
    local message=$1 output
    shift
    output=$(update_crl "$@" 2>&1) && return 1
    echo "$output"
    grep -qF "$message" <<< "$output"
}

refuses_other_ca_crl() {
    env EASYRSA_PASSOUT=pass:test EASYRSA_PASSIN=pass:test bash "$ROOT/scripts/pki.sh" "$WORK/other-ca" init &&
        refuses_crl "CRL is not signed by the CA of the bundle" "$WORK/other-ca/pki/crl.pem"
}

# gw-vpn with its clock one hour behind the CA: the CRL is dated in its future.
refuses_future_crl() {
    local output
    mkdir "$WORK/slow-clock"
    cat > "$WORK/slow-clock/date" <<'EOF'
#!/bin/sh
[ "$*" = "+%s" ] && echo $(( $(/usr/bin/date +%s) - 3600 )) || exec /usr/bin/date "$@"
EOF
    chmod +x "$WORK/slow-clock/date"
    output=$(PATH="$WORK/slow-clock:$PATH" update_crl "$CRL" 2>&1) && return 1
    echo "$output"
    grep -q "dated in the future" <<< "$output"
}

# update_crl_says MESSAGE ARGUMENT...: update-crl succeeds and prints MESSAGE.
update_crl_says() {
    local message=$1 output
    shift
    output=$(update_crl "$@") || return 1
    echo "$output"
    grep -qxF "$message" <<< "$output"
}

# The bundle still has the CCD file of dev-01, so only the CRL can reject it.
reconnection_rejected_by_crl() {
    ip netns exec "$DEV_NS" openvpn --config "$WORK/dev-01.ovpn" --disable-dco --daemon --log "$WORK/dev-01-again.log" \
        --writepid "$WORK/dev-01-again.pid" &&
        wait_for "error=certificate revoked: CN=dev-01" "$WORK/server.log" &&
        ! connected dev-01
}

connect_admin_01() {
    openvpn --config "$WORK/admin-01.ovpn" --dev tun12 --disable-dco --daemon --log "$WORK/admin-01.log" \
        --writepid "$WORK/admin-01.pid" --route-noexec --ifconfig-noexec --script-security 0 &&
        wait_for "Initialization Sequence Completed" "$WORK/admin-01.log"
}

# Opens the directory and the socket to everyone, so that only the server can refuse nobody.
management_only_for_root() {
    local as_root as_nobody mode
    mode=$(stat -c %a "$(dirname "$MANAGEMENT_SOCKET")")
    chmod 755 "$(dirname "$MANAGEMENT_SOCKET")" && chmod 666 "$MANAGEMENT_SOCKET" || return 1
    as_root=$(socat -T2 -t2 - "UNIX-CONNECT:$MANAGEMENT_SOCKET" <<< quit 2>&1)
    as_nobody=$(setpriv --reuid=nobody --regid=nogroup --clear-groups \
        socat -T2 -t2 - "UNIX-CONNECT:$MANAGEMENT_SOCKET" <<< quit 2>&1)
    chmod "$mode" "$(dirname "$MANAGEMENT_SOCKET")"
    echo "root: ${as_root:-nothing}"
    echo "nobody: ${as_nobody:-nothing}"
    [[ $as_root == *"OpenVPN Management Interface"* && $as_nobody != *"OpenVPN Management Interface"* ]]
}

run "Only root can use the management interface" management_only_for_root
cp "$WORK/bundle/crl.pem" "$WORK/old-crl.pem"
sleep 1   # lastUpdate has a resolution of one second
run "admin-01 connects as a second user" connect_admin_01
run "dev-01 and admin-01 are connected" both_connected
run "The CA revokes dev-01" pki revoke dev-01
run "update-crl refuses a CRL of another CA" refuses_other_ca_crl
run "update-crl refuses names that are not plain identifiers" \
    refuses_crl "Invalid certificate name" "$CRL" $'dev-01\nsignal SIGTERM'
run "update-crl refuses a CRL dated in the future" refuses_future_crl
run "update-crl installs the CRL and ends the dev-01 session" update_crl_says "dev-01: session ended" "$CRL" dev-01
run "The dev-01 session is gone" disconnected dev-01
run "admin-01 stays connected" connected admin-01
run "A new dev-01 connection is rejected by the CRL" reconnection_rejected_by_crl
run "update-crl refuses a CRL older than the installed one" \
    refuses_crl "CRL is older than the installed one" "$WORK/old-crl.pem"
run "update-crl reports a name that is not connected" update_crl_says "ghost-01: not connected" "$CRL" ghost-01
run "admin-01 stays connected through the refused CRLs and the rejected reconnection" connected admin-01

exit "$FAILED"
