#!/usr/bin/env bash
# Tests gateway/dnsmasq/the-store.conf: starts dnsmasq without root on a high port of
# 127.0.0.1 and queries it. Requires dnsmasq and dig.
set -uo pipefail

CONF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gateway/dnsmasq/the-store.conf
PORT=${DNSMASQ_TEST_PORT:-15353}
NODE_IP=10.10.10.5
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

resolves_to_node() {
    local answer
    answer=$(dig @127.0.0.1 -p "$PORT" +short +time=2 +tries=1 "$1" A)
    echo "$1 -> ${answer:-no answer}"
    [[ $answer == "$NODE_IP" ]]
}

# answers_status NAME STATUS: the DNS status of the answer (NXDOMAIN, REFUSED, ...).
answers_status() {
    local status
    status=$(dig @127.0.0.1 -p "$PORT" +time=2 +tries=1 "$1" A | grep -o 'status: [A-Z]*')
    echo "$1 -> ${status:-no answer}"
    [[ $status == "status: $2" ]]
}

run "Configuration is valid" dnsmasq --test --conf-file="$CONF"
dnsmasq --conf-file="$CONF" --port="$PORT" --keep-in-foreground --pid-file= --user="$(id -un)" &
DNSMASQ_PID=$!
trap 'kill "$DNSMASQ_PID" 2> /dev/null' EXIT
sleep 1

for service in ui catalog carts orders checkout; do
    run "$service.the-store.internal resolves to $NODE_IP" resolves_to_node "$service.the-store.internal"
done
run "Unknown name in the-store.internal gets NXDOMAIN" answers_status unknown.the-store.internal NXDOMAIN
run "External name gets REFUSED" answers_status example.com REFUSED
run "Names from /etc/hosts are not served" answers_status localhost NXDOMAIN
exit "$FAILED"
