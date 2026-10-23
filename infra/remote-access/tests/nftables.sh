#!/usr/bin/env bash
# Tests gateway/nftables/nftables.conf: validates filtering rules, default policies,
# role-based access control matching Section 6 of the project PDF, and verifies
# that nftables parses the ruleset without syntax errors.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONF=$ROOT/gateway/nftables/nftables.conf
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

matches_pattern() {
    grep -qE "$1" "$CONF"
}

run "Configuration file exists" test -f "$CONF"
run "Has flush ruleset" grep -q "flush ruleset" "$CONF"

# Default policies (Denegación por defecto - CU1)
chain_has_policy_drop() {
    grep -A 5 "chain $1" "$CONF" | grep -q "policy drop"
}

run "Input chain has drop policy" chain_has_policy_drop input
run "Forward chain has drop policy" chain_has_policy_drop forward

# Input chain rules
run "Input allows loopback interface" matches_pattern 'iif[[:space:]]+"lo"[[:space:]]+accept'
run "Input allows established and related connections" matches_pattern 'ct[[:space:]]+state[[:space:]]+established,related[[:space:]]+accept'
run "Input accepts OpenVPN UDP 1194 on eth0 from 203.0.113.0/24" matches_pattern 'iif[[:space:]]+"eth0"[[:space:]]+ip[[:space:]]+saddr[[:space:]]+203\.0\.113\.0/24[[:space:]]+udp[[:space:]]+dport[[:space:]]+1194[[:space:]]+accept'
run "Input accepts Split-DNS (port 53) on tun0 from 10.8.0.0/24" matches_pattern 'iif[[:space:]]+"tun0"[[:space:]]+ip[[:space:]]+saddr[[:space:]]+10\.8\.0\.0/24.*dport[[:space:]]+53[[:space:]]+accept'
run "Input accepts SSH (port 22) on eth2 from 192.168.100.0/24" matches_pattern 'iif[[:space:]]+"eth2"[[:space:]]+ip[[:space:]]+saddr[[:space:]]+192\.168\.100\.0/24[[:space:]]+tcp[[:space:]]+dport[[:space:]]+22[[:space:]]+accept'

# Forward chain rules (Role-based access matrix)
run "Forward allows established and related connections" grep -A 10 "chain forward" "$CONF" | grep -q "ct state established,related accept"
run "Forward allows dev role (10.8.0.10-.19) to Ingress (10.10.10.5:80)" matches_pattern '10\.8\.0\.10-10\.8\.0\.19.*10\.10\.10\.5.*tcp[[:space:]]+dport[[:space:]]+80[[:space:]]+accept'
run "Forward allows sucursal role (172.16.20.0/24) to Ingress (10.10.10.5:80)" matches_pattern '172\.16\.20\.0/24.*10\.10\.10\.5.*tcp[[:space:]]+dport[[:space:]]+80[[:space:]]+accept'
run "Forward allows sysadmin role (10.8.0.20-.29) to SSH, 6443, 80 on 10.10.10.5" matches_pattern '10\.8\.0\.20-10\.8\.0\.29.*10\.10\.10\.5.*22.*6443.*80.*accept'

# NAT postrouting
run "NAT postrouting table and chain exist" grep -q "table ip nat" "$CONF"
run "SNAT translates tunnel and branch traffic to 10.10.0.1 on eth1" matches_pattern 'oif[[:space:]]+"eth1".*snat[[:space:]]+to[[:space:]]+10\.10\.0\.1'

# Syntax validation using nftables bison parser
test_nft_syntax() {
    local output
    output=$(nft -d parser -f "$CONF" 2>&1)
    if grep -q "Error: syntax error" <<< "$output"; then
        echo "$output"
        return 1
    fi
    # Check that parser reached end of input without syntax error
    grep -q "Now at end of input" <<< "$output"
}

run "nftables parser validates ruleset syntax" test_nft_syntax

exit "$FAILED"
