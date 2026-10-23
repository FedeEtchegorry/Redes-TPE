#!/usr/bin/env bash
# Tests gateway/openvpn/server.conf: validates configuration directives,
# cryptographic options, and checks that OpenVPN parses the file without errors.
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
run "Enables tls-crypt with key" has_directive "tls-crypt tls-crypt.key"
run "Enforces CRL verification" has_directive "crl-verify crl.pem"

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

exit "$FAILED"
