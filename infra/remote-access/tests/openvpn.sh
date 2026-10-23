#!/usr/bin/env bash
# Tests gateway/openvpn/server.conf: validates configuration directives,
# cryptographic options, and checks that OpenVPN parses the file without errors.
# Run with sudo: it starts a real server and clients, which need tun devices.
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

has_directive_exact() {
    grep -qF "$1" "$CONF"
}

run "Configuration file exists" test -f "$CONF"

# Core network & interface options
run "Listens on UDP port 1194" has_directive "port 1194"
run "Uses UDP protocol" has_directive "proto udp"
run "Binds to tun0 interface" has_directive "dev tun0"
run "Uses subnet topology" has_directive "topology subnet"
run "Configures 10.8.0.0/24 VPN server pool" has_directive "server 10.8.0.0 255.255.255.0"

# Cryptography and PKI options
run "Uses ECDH without DH file (dh none)" has_directive "dh none"
run "Enforces minimum TLS 1.3" has_directive "tls-version-min 1.3"
run "Uses AES-256-GCM cipher" has_directive "cipher AES-256-GCM"
run "Data channel is AES-256-GCM only (no other data-ciphers)" has_directive "data-ciphers AES-256-GCM"
run "Enables tls-crypt with key" has_directive "tls-crypt tls-crypt.key"
run "Enforces CRL verification" has_directive "crl-verify crl.pem"
run "Requires the client certificate purpose (remote-cert-tls client)" has_directive "remote-cert-tls client"

does_not_push_redirect_gateway() {
    ! grep -nE '^[^#]*redirect-gateway' "$CONF"
}

run "Does not redirect the clients' default gateway (split tunnel)" does_not_push_redirect_gateway

# Routing and access control
run "Configures client-config-dir (ccd)" has_directive "client-config-dir ccd"
run "Routes branch LAN 172.16.20.0/24" has_directive "route 172.16.20.0 255.255.255.0"
run "Pushes split-DNS server 10.8.0.1" has_directive_exact 'push "dhcp-option DNS 10.8.0.1"'
run "Pushes domain the-store.internal" has_directive_exact 'push "dhcp-option DOMAIN the-store.internal"'

# Management interface for session termination (CU4)
run "Configures management interface on 127.0.0.1:7505" has_directive "management 127.0.0.1 7505"

# Operational directives
run "Enables keepalive" has_directive "keepalive 10 120"
run "Enables explicit-exit-notify" has_directive "explicit-exit-notify 1"

# OpenVPN parser and crypto self-test using temporary certs and keys
test_openvpn_parsing() {
    local tmpdir output
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    # Generate dummy EC certificate and tls-crypt key to satisfy parser file checks
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "$tmpdir/gw-vpn.key" 2>/dev/null
    openssl req -new -x509 -key "$tmpdir/gw-vpn.key" -out "$tmpdir/gw-vpn.crt" -days 1 -subj "/CN=gw-vpn" 2>/dev/null
    cp "$tmpdir/gw-vpn.crt" "$tmpdir/ca.crt"
    openvpn --genkey secret "$tmpdir/tls-crypt.key" 2>/dev/null
    mkdir -p "$tmpdir/ccd"

    # Copy server.conf without crl-verify (as crl requires an active CA structure)
    grep -v "crl-verify" "$CONF" > "$tmpdir/server.conf"

    # Run openvpn with --management-client so it verifies options and terminates cleanly
    (cd "$tmpdir" && openvpn --config server.conf --verb 1 --management-client 2>&1)
}

run "OpenVPN binary validates server configuration" test_openvpn_parsing

# Real server and clients, using the bundle from scripts/pki.sh. Needs EasyRSA 3.
WORK=
GATEWAY_IP=203.0.113.10   # remote of clients/client.conf

cleanup() {
    local pid
    [[ $FAILED == 0 ]] || tail -n 15 "$WORK"/*.log
    for pid in $(cat "$WORK"/*.pid 2>/dev/null); do
        kill "$pid" 2>/dev/null
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    done
    ip addr del "$GATEWAY_IP/32" dev lo 2>/dev/null
    rm -rf "$WORK"
}

pki() { env EASYRSA_PASSOUT=pass:test EASYRSA_PASSIN=pass:test bash "$ROOT/scripts/pki.sh" "$WORK/ca" "$@"; }

wait_for() { timeout 10 bash -c 'until grep -q "$0" "$1" 2>/dev/null; do sleep 0.2; done' "$1" "$2"; }

issue_certificates() {
    local client
    pki init && pki issue-server &&
        pki issue-client dev-01 dev 10 && pki export-server "$WORK/bundle" &&
        pki issue-client rogue dev 11 || return 1   # after the export: no CCD file in the bundle
    for client in dev-01 rogue; do
        pki export-client "$client" "$WORK/$client.ovpn" || return 1
    done
}

start_server() {
    cp "$CONF" "$WORK/bundle/server.conf"
    # --cd: server.conf uses relative paths.
    openvpn --cd "$WORK/bundle" --config server.conf --daemon --log "$WORK/server.log" \
        --writepid "$WORK/server.pid" &&
        wait_for "Initialization Sequence Completed" "$WORK/server.log" &&
        ip -4 addr show dev tun0 | grep -q "inet 10\.8\.0\.1/24"
}

WORK=$(mktemp -d)
trap cleanup EXIT
ip addr add "$GATEWAY_IP/32" dev lo
run "pki.sh issues the certificates and exports the gateway bundle" issue_certificates
run "OpenVPN server starts with the bundle (tun0 is 10.8.0.1/24)" start_server

i=11
for client in dev-01 rogue; do
    openvpn --config "$WORK/$client.ovpn" --dev "tun$((i++))" --daemon --log "$WORK/$client.log" \
        --writepid "$WORK/$client.pid" --route-noexec --ifconfig-noexec --script-security 0
done
wait_for "Initialization Sequence Completed" "$WORK/dev-01.log"
wait_for "authentication failed for common name 'rogue'" "$WORK/server.log"

run "dev-01 gets its fixed IP 10.8.0.10 from its CCD" grep -q "MULTI: Learn: 10.8.0.10 -> dev-01/" "$WORK/server.log"
run "A valid certificate without a CCD file is rejected (ccd-exclusive)" grep -q "authentication failed for common name 'rogue'" "$WORK/server.log"

exit "$FAILED"
