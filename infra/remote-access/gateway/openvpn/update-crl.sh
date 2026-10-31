#!/usr/bin/env bash
# Installs on gw-vpn the CRL it reads from standard input, as sent by scripts/pki.sh
# publish-crl, then ends the sessions of the given names through the management interface (CU4).
# Usage: update-crl.sh [COMMON_NAME...] < CRL. Run as root, installed as
# /usr/local/sbin/the-store-update-crl. Requires OpenSSL and socat.
set -euo pipefail

BUNDLE_DIR=${BUNDLE_DIR:-/etc/openvpn/server/the-store}
MANAGEMENT_SOCKET=${MANAGEMENT_SOCKET:-/run/openvpn-server/the-store.sock}
CRL=$BUNDLE_DIR/crl.pem.new

fail() {
    echo "$*" >&2
    exit 1
}

# management COMMAND: prints the response to COMMAND, up to its SUCCESS, ERROR or END line.
# quit is sent only then, because OpenVPN drops a pending response when it closes.
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

# crl_date FILE FIELD: the lastupdate or nextupdate date of FILE, in seconds.
crl_date() {
    date -d "$(openssl crl -in "$1" -noout "-$2" | cut -d= -f2)" +%s
}

# Names are checked before anything changes: a newline would send another management command.
for NAME in "$@"; do
    [[ "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || fail "Invalid certificate name"
done

# The CRL is read once, from standard input, into a file only root can write: root never opens
# a path chosen by the caller, which could be swapped for a symlink after the checks.
trap 'rm -f "$CRL"' EXIT
cat > "$CRL"

# openssl crl exits with 0 even when the signature does not verify, so its message is checked.
[[ $(openssl crl -in "$CRL" -CAfile "$BUNDLE_DIR/ca.crt" -noout 2>&1) == *"verify OK"* ]] ||
    fail "CRL is not signed by the CA of the bundle"
NEXT_UPDATE=$(crl_date "$CRL" nextupdate)
LAST_UPDATE=$(crl_date "$CRL" lastupdate)
NOW=$(date +%s)
(( NEXT_UPDATE > NOW )) || fail "CRL has expired"
(( NEXT_UPDATE > NOW + 7 * 86400 )) || echo "Warning: CRL expires in less than 7 days" >&2
# OpenSSL rejects every client while the CRL is dated in the future, as with a CA clock ahead.
(( LAST_UPDATE <= NOW )) || fail "CRL is dated in the future: check the clocks of the CA and gw-vpn"
# An older CRL would accept again the certificates revoked since.
(( LAST_UPDATE > $(crl_date "$BUNDLE_DIR/crl.pem" lastupdate) )) ||
    cmp -s "$CRL" "$BUNDLE_DIR/crl.pem" ||
    fail "CRL is older than the installed one or conflicts with it; regenerate and retry"

# OpenVPN reads crl.pem on each connection, as the nobody user: the rename keeps it from
# reading a partial file.
chmod 644 "$CRL"
mv -f "$CRL" "$BUNDLE_DIR/crl.pem"
echo "CRL installed"

# Only after the CRL is in place, so that the reconnection of a killed client is rejected.
# kill ends every session of that name and no other.
for NAME in "$@"; do
    RESPONSE=$(management "kill $NAME")
    if grep -q '^SUCCESS: common name' <<< "$RESPONSE"; then
        echo "$NAME: session ended"
    elif grep -q "^ERROR: common name '$NAME' not found" <<< "$RESPONSE"; then
        echo "$NAME: not connected"
    else
        fail "$NAME: unexpected management response: $RESPONSE"
    fi
done
