#!/usr/bin/env bash
# Installs on gw-vpn a CRL sent by scripts/pki.sh publish-crl, then ends the sessions of the
# given names through the management interface (CU4). Run as root, installed as
# /usr/local/sbin/the-store-update-crl. Requires OpenSSL and socat.
set -euo pipefail

BUNDLE_DIR=${BUNDLE_DIR:-/etc/openvpn/server/the-store}
MANAGEMENT_SOCKET=${MANAGEMENT_SOCKET:-/run/openvpn-server/the-store.sock}
CRL=${1:?Usage: update-crl.sh CRL_FILE [COMMON_NAME...]}
shift

fail() {
    echo "$*" >&2
    exit 1
}

# crl_date FILE FIELD: the lastupdate or nextupdate date of FILE, in seconds.
crl_date() {
    date -d "$(openssl crl -in "$1" -noout "-$2" | cut -d= -f2)" +%s
}

# Names are checked before anything changes: a newline would send another management command.
for NAME in "$@"; do
    [[ "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || fail "Invalid certificate name"
done

# openssl crl exits with 0 even when the signature does not verify, so its message is checked.
[[ $(openssl crl -in "$CRL" -CAfile "$BUNDLE_DIR/ca.crt" -noout 2>&1) == *"verify OK"* ]] ||
    fail "CRL is not signed by the CA of the bundle"
NEXT_UPDATE=$(crl_date "$CRL" nextupdate)
(( NEXT_UPDATE > $(date +%s) )) || fail "CRL has expired"
(( NEXT_UPDATE > $(date +%s) + 7 * 86400 )) || echo "Warning: CRL expires in less than 7 days" >&2
# An older CRL would accept again the certificates revoked since.
(( $(crl_date "$CRL" lastupdate) >= $(crl_date "$BUNDLE_DIR/crl.pem" lastupdate) )) ||
    fail "CRL is older than the installed one"

# OpenVPN reads crl.pem on each connection, as the nobody user: the rename keeps it from
# reading a partial file.
install -m 644 "$CRL" "$BUNDLE_DIR/crl.pem.new"
mv -f "$BUNDLE_DIR/crl.pem.new" "$BUNDLE_DIR/crl.pem"
echo "CRL installed"

# Only after the CRL is in place, so that the reconnection of a killed client is rejected.
# kill ends every session of that name and no other.
for NAME in "$@"; do
    RESPONSE=$(printf 'kill %s\nquit\n' "$NAME" | socat -t 5 - "UNIX-CONNECT:$MANAGEMENT_SOCKET")
    if grep -q '^SUCCESS: common name' <<< "$RESPONSE"; then
        echo "$NAME: session ended"
    elif grep -q "^ERROR: common name '$NAME' not found" <<< "$RESPONSE"; then
        echo "$NAME: not connected"
    else
        fail "$NAME: unexpected management response: $RESPONSE"
    fi
done
