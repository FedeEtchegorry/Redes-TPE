#!/usr/bin/env bash
# Tests gateway/openvpn/server.conf: checks its directives, then runs it with the bundle of
# scripts/pki.sh, connects clients and revokes one of them. Run with sudo; requires EasyRSA 3,
# ping and socat.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONF=$ROOT/gateway/openvpn/server.conf
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

has_directive() {
    grep -qE "^[[:space:]]*$1([[:space:]]+|$)" "$CONF"
}

# lacks PATTERN: no line outside comments matches PATTERN.
lacks() {
    ! grep -nE "^[^#]*$1" "$CONF"
}

# Core network & interface options
run "Listens only on 203.0.113.10" has_directive "local 203.0.113.10"
run "Listens on UDP port 1194" has_directive "port 1194"
run "Uses UDP over IPv4" has_directive "proto udp4"
run "Binds to tun0 interface" has_directive "dev tun0"
run "Uses subnet topology" has_directive "topology subnet"
run "Configures 10.8.0.0/24 VPN server pool" has_directive "server 10.8.0.0 255.255.255.0"

# Cryptography and PKI options
run "Uses ECDH without DH file (dh none)" has_directive "dh none"
run "Enforces minimum TLS 1.3" has_directive "tls-version-min 1.3"
run "Data channel is AES-256-GCM only (no other data-ciphers)" has_directive "data-ciphers AES-256-GCM"
run "Enables tls-crypt with key" has_directive "tls-crypt /etc/openvpn/server/the-store/tls-crypt.key"
run "Enforces CRL verification" has_directive "crl-verify /etc/openvpn/server/the-store/crl.pem"
run "Requires the client certificate purpose (remote-cert-tls client)" has_directive "remote-cert-tls client"

run "Does not redirect the clients' default gateway (split tunnel)" lacks redirect-gateway

# Routing and access control
run "Configures client-config-dir (ccd)" has_directive "client-config-dir /etc/openvpn/server/the-store/ccd"
run "Routes branch LAN 172.16.20.0/24" has_directive "route 172.16.20.0 255.255.255.0"
run "Pushes split-DNS server 10.8.0.1" has_directive 'push "dns server 0 address 10.8.0.1"'
run "Sends only the-store.internal to it" has_directive 'push "dns server 0 resolve-domains the-store.internal"'
run "Does not set the DNS of the adapter" lacks '(dhcp-option|search-domains)'

# Management interface for session termination (CU4)
run "Configures management interface on a Unix socket" has_directive "management /run/openvpn-server/the-store.sock unix"
run "Only root can use the management interface" has_directive "management-client-user root"

# Operational directives
run "Enables keepalive" has_directive "keepalive 10 120"
run "Enables explicit-exit-notify" has_directive "explicit-exit-notify 1"
run "Drops root to nobody:nogroup" has_directive "user nobody"

# Real server and clients, using the bundle from scripts/pki.sh. Needs EasyRSA 3.
WORK=
GATEWAY_IP=203.0.113.10   # remote of clients/client.conf
DEV_NS=the-store-dev      # network namespace of dev-01

cleanup() {
    local pid
    [[ $FAILED == 0 ]] || tail -n 15 "$WORK"/*.log
    for pid in $(cat "$WORK"/*.pid 2>/dev/null); do
        kill "$pid" 2>/dev/null
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    done
    ip netns delete "$DEV_NS" 2>/dev/null
    ip addr del "$GATEWAY_IP/32" dev lo 2>/dev/null
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

WORK=$(mktemp -d)
trap cleanup EXIT
ip addr add "$GATEWAY_IP/32" dev lo
run "pki.sh issues the certificates and exports the gateway bundle" issue_certificates
run "OpenVPN server starts with the bundle (tun0 is 10.8.0.1/24)" start_server
run "dev-01 connects from the untrusted segment" connect_dev_01

openvpn --config "$WORK/rogue.ovpn" --dev tun11 --daemon --log "$WORK/rogue.log" \
    --writepid "$WORK/rogue.pid" --route-noexec --ifconfig-noexec --script-security 0
wait_for "authentication failed for common name 'rogue'" "$WORK/server.log"

run "dev-01 gets its fixed IP 10.8.0.10 from its CCD" grep -q "MULTI: Learn: 10.8.0.10 -> dev-01/" "$WORK/server.log"
run "A valid certificate without a CCD file is rejected (ccd-exclusive)" grep -q "authentication failed for common name 'rogue'" "$WORK/server.log"
run "dev-01 routes only the node 10.10.10.5 through the tunnel (split tunnel)" routes_only_the_node
run "dev-01 cannot send with the sysadmin address 10.8.0.20" spoofed_source_dropped 10.8.0.20

# Revocation (CU4): a second user stays connected while dev-01 is revoked.
MANAGEMENT_SOCKET=/run/openvpn-server/the-store.sock
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

refuses_crl() { ! update_crl "$@"; }

refuses_other_ca_crl() {
    env EASYRSA_PASSOUT=pass:test EASYRSA_PASSIN=pass:test bash "$ROOT/scripts/pki.sh" "$WORK/other-ca" init &&
        refuses_crl "$WORK/other-ca/pki/crl.pem"
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

cp "$WORK/bundle/crl.pem" "$WORK/old-crl.pem"
sleep 1   # lastUpdate has a resolution of one second
run "admin-01 connects as a second user" connect_admin_01
run "dev-01 and admin-01 are connected" both_connected
run "The CA revokes dev-01" pki revoke dev-01
run "update-crl refuses a CRL of another CA" refuses_other_ca_crl
run "update-crl refuses names that are not plain identifiers" refuses_crl "$CRL" $'dev-01\nsignal SIGTERM'
run "update-crl refuses a CRL dated in the future" refuses_future_crl
run "update-crl installs the CRL and ends the dev-01 session" update_crl_says "dev-01: session ended" "$CRL" dev-01
run "The dev-01 session is gone" disconnected dev-01
run "admin-01 stays connected" connected admin-01
run "A new dev-01 connection is rejected by the CRL" reconnection_rejected_by_crl
run "update-crl refuses a CRL older than the installed one" refuses_crl "$WORK/old-crl.pem"
run "update-crl reports a name that is not connected" update_crl_says "ghost-01: not connected" "$CRL" ghost-01
run "admin-01 is still connected" connected admin-01

exit "$FAILED"
