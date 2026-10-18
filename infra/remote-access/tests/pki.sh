#!/usr/bin/env bash
# Tests scripts/pki.sh in a temporary directory. Requires EasyRSA 3, OpenVPN and OpenSSL.
set -uo pipefail

PKI_SH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/pki.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CA_DIR=$WORK/ca
PKI=$CA_DIR/pki
PASSPHRASE=test-passphrase
export EASYRSA_PASSOUT=pass:$PASSPHRASE EASYRSA_PASSIN=pass:$PASSPHRASE
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

ca_key_needs_passphrase() {
    openssl pkey -in "$PKI/private/ca.key" -passin "pass:$PASSPHRASE" -noout &&
        ! openssl pkey -in "$PKI/private/ca.key" -passin pass: -noout
}

ca_certificate() {
    local text
    text=$(openssl x509 -in "$PKI/ca.crt" -noout -text)
    grep -q 'Subject: CN = The Store VPN CA' <<< "$text" &&
        grep -q 'CA:TRUE' <<< "$text" &&
        grep -q 'ASN1 OID: prime256v1' <<< "$text"
}

# openssl crl exits with 0 even when the signature does not verify, so the test
# checks its message.
crl_signed_by_ca() {
    local result
    result=$(openssl crl -in "$PKI/crl.pem" -CAfile "$PKI/ca.crt" -noout 2>&1)
    echo "$result"
    [[ $result == *"verify OK"* ]]
}

tls_crypt_key() {
    grep -q 'BEGIN OpenVPN Static key V1' "$CA_DIR/tls-crypt.key"
}

init_refuses_overwrite() {
    ! bash "$PKI_SH" "$CA_DIR" init
}

server_certificate() {
    local text
    openssl verify -CAfile "$PKI/ca.crt" "$PKI/issued/gw-vpn.crt" &&
        text=$(openssl x509 -in "$PKI/issued/gw-vpn.crt" -noout -text) &&
        grep -q 'Subject: CN = gw-vpn' <<< "$text" &&
        grep -q 'TLS Web Server Authentication' <<< "$text"
}

server_key_without_passphrase() {
    openssl pkey -in "$PKI/private/gw-vpn.key" -passin pass: -noout
}

run "init creates the CA" bash "$PKI_SH" "$CA_DIR" init
run "CA key requires the passphrase" ca_key_needs_passphrase
run "CA certificate is a prime256v1 CA named The Store VPN CA" ca_certificate
run "CRL is signed by the CA" crl_signed_by_ca
run "tls-crypt key is an OpenVPN static key" tls_crypt_key
run "init refuses to overwrite an existing PKI" init_refuses_overwrite
run "issue-server creates the gw-vpn certificate" bash "$PKI_SH" "$CA_DIR" issue-server
run "gw-vpn certificate is signed by the CA for TLS servers" server_certificate
run "gw-vpn key has no passphrase" server_key_without_passphrase
exit "$FAILED"
