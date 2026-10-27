#!/usr/bin/env bash
# Tests scripts/pki.sh in a temporary directory. Requires EasyRSA 3, OpenVPN and OpenSSL.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PKI_SH=$ROOT/scripts/pki.sh
CLIENT_CONF=$ROOT/clients/client.conf
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CA_DIR=$WORK/ca
PKI=$CA_DIR/pki
BUNDLE=$WORK/gateway-bundle
PROFILES=$WORK/profiles
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
    grep -qE 'Subject: CN ?= ?The Store VPN CA$' <<< "$text" &&
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

refuses() {
    ! bash "$PKI_SH" "$CA_DIR" "$@"
}

server_certificate() {
    local text
    openssl verify -CAfile "$PKI/ca.crt" "$PKI/issued/gw-vpn.crt" &&
        text=$(openssl x509 -in "$PKI/issued/gw-vpn.crt" -noout -text) &&
        grep -qE 'Subject: CN ?= ?gw-vpn$' <<< "$text" &&
        grep -q 'TLS Web Server Authentication' <<< "$text"
}

server_key_without_passphrase() {
    openssl pkey -in "$PKI/private/gw-vpn.key" -passin pass: -noout
}

client_certificates() {
    local client text
    for client in "$@"; do
        openssl verify -CAfile "$PKI/ca.crt" "$PKI/issued/$client.crt" || return 1
        text=$(openssl x509 -in "$PKI/issued/$client.crt" -noout -text)
        grep -qE "Subject: CN ?= ?$client\$" <<< "$text" || { echo "$client: unexpected subject"; return 1; }
        grep -q 'TLS Web Client Authentication' <<< "$text" || { echo "$client: not a TLS client"; return 1; }
    done
}

client_keys_without_passphrase() {
    local client
    for client in "$@"; do
        openssl pkey -in "$PKI/private/$client.key" -passin pass: -noout || return 1
    done
}

# ccd_is NAME CONTENT: the CCD file of NAME has exactly CONTENT.
ccd_is() {
    local content
    content=$(cat "$CA_DIR/ccd/$1")
    echo "$content"
    [[ $content == "$2" ]]
}

# only_clients NAME...: the CCD files and client certificates are exactly NAME...
only_clients() {
    local expected ccd issued
    expected=$(printf '%s\n' "$@" | sort | paste -sd ' ')
    ccd=$(find "$CA_DIR/ccd" -type f -printf '%f\n' | sort | paste -sd ' ')
    issued=$(find "$PKI/issued" -name '*.crt' ! -name gw-vpn.crt -printf '%f\n' | sed 's/\.crt$//' | sort | paste -sd ' ')
    echo "ccd: $ccd"
    echo "certificates: $issued"
    [[ $ccd == "$expected" && $issued == "$expected" ]]
}

# listing_is DIRECTORY LISTING: the permissions and paths under DIRECTORY are exactly LISTING.
listing_is() {
    local listing
    listing=$(cd "$1" && find . -printf '%m %p\n' | LC_ALL=C sort -k2)
    echo "$listing"
    [[ $listing == "$2" ]]
}

# block NAME FILE: the lines inside the inline <NAME> block of a profile.
block() {
    sed -n "/^<$1>\$/,/^<\/$1>\$/{//!p}" "$2"
}

# profile_of NAME: the profile of NAME has the client.conf options, the CA, the tls-crypt
# key, and the certificate and key of NAME as its only certificate and private key.
profile_of() {
    local profile=$PROFILES/$1.ovpn
    [[ $(sed '/^<ca>$/,$d' "$profile") == "$(cat "$CLIENT_CONF")" ]] || { echo "Options differ from client.conf"; return 1; }
    [[ $(block ca "$profile") == "$(cat "$PKI/ca.crt")" ]] || { echo "Unexpected CA"; return 1; }
    [[ $(block cert "$profile") == "$(openssl x509 -in "$PKI/issued/$1.crt")" ]] || { echo "Unexpected certificate"; return 1; }
    [[ $(block key "$profile") == "$(cat "$PKI/private/$1.key")" ]] || { echo "Unexpected key"; return 1; }
    [[ $(block tls-crypt "$profile") == "$(cat "$CA_DIR/tls-crypt.key")" ]] || { echo "Unexpected tls-crypt key"; return 1; }
    [[ $(grep -c -- '-----BEGIN' "$profile") == 4 ]] || { echo "Unexpected PEM blocks"; return 1; }
}

# OpenVPN exits at once on an invalid option or a key that does not match the certificate;
# with a valid profile it keeps trying to reach the server until timeout stops it. The copy
# points to a closed local port so that no packet leaves the machine.
openvpn_loads() {
    local profile=$WORK/$1-local.ovpn
    sed 's/^remote .*/remote 127.0.0.1 1/' "$PROFILES/$1.ovpn" > "$profile"
    timeout 3 openvpn --config "$profile"
    [[ $? == 124 ]]
}

run "init creates the CA" bash "$PKI_SH" "$CA_DIR" init
run "CA key requires the passphrase" ca_key_needs_passphrase
run "CA certificate is a prime256v1 CA named The Store VPN CA" ca_certificate
run "CRL is signed by the CA" crl_signed_by_ca
run "tls-crypt key is an OpenVPN static key" tls_crypt_key
run "init refuses to overwrite an existing PKI" refuses init
run "issue-client refuses the gw-vpn name" refuses issue-client gw-vpn dev 11
run "issue-server creates the gw-vpn certificate" bash "$PKI_SH" "$CA_DIR" issue-server
run "gw-vpn certificate is signed by the CA for TLS servers" server_certificate
run "gw-vpn key has no passphrase" server_key_without_passphrase

run "issue-client creates dev-01 as dev at .10" bash "$PKI_SH" "$CA_DIR" issue-client dev-01 dev 10
run "issue-client creates admin-01 as sysadmin at .20" bash "$PKI_SH" "$CA_DIR" issue-client admin-01 sysadmin 20
run "issue-client refuses gw-sucursal outside the sucursal role" refuses issue-client gw-sucursal dev 12
run "issue-client refuses the sucursal role for another name" refuses issue-client branch-02 sucursal 30
run "issue-client creates gw-sucursal as sucursal at .30" bash "$PKI_SH" "$CA_DIR" issue-client gw-sucursal sucursal 30
run "Client certificates are signed by the CA for TLS clients" client_certificates dev-01 admin-01 gw-sucursal
run "Client keys have no passphrase" client_keys_without_passphrase dev-01 admin-01 gw-sucursal
run "issue-client refuses a dev IP outside .10-.19" refuses issue-client dev-02 dev 25
run "issue-client refuses a sysadmin IP outside .20-.29" refuses issue-client admin-02 sysadmin 15
run "issue-client refuses an IP that is already assigned" refuses issue-client dev-02 dev 10
run "issue-client refuses an existing name" refuses issue-client dev-01 dev 13
run "issue-client refuses the DEFAULT name" refuses issue-client DEFAULT dev 14
run "issue-client refuses names that are not plain identifiers" refuses issue-client ../dev-02 dev 16

ROUTE='push "route 10.10.10.5 255.255.255.255"'
run "dev-01 CCD assigns 10.8.0.10 and only routes the node" \
    ccd_is dev-01 "ifconfig-push 10.8.0.10 255.255.255.0"$'\n'"$ROUTE"
run "admin-01 CCD assigns 10.8.0.20 and only routes the node" \
    ccd_is admin-01 "ifconfig-push 10.8.0.20 255.255.255.0"$'\n'"$ROUTE"
run "gw-sucursal CCD assigns 10.8.0.30, routes the node and owns the branch LAN" \
    ccd_is gw-sucursal "ifconfig-push 10.8.0.30 255.255.255.0"$'\n'"$ROUTE"$'\n'"iroute 172.16.20.0 255.255.255.0"
run "Refused requests leave no certificate or CCD" only_clients dev-01 admin-01 gw-sucursal

run "export-server writes the gateway bundle" bash "$PKI_SH" "$CA_DIR" export-server "$BUNDLE"
run "Gateway bundle has the gateway files and CCDs, without the CA key" listing_is "$BUNDLE" "755 .
644 ./ca.crt
755 ./ccd
644 ./ccd/admin-01
644 ./ccd/dev-01
644 ./ccd/gw-sucursal
644 ./crl.pem
644 ./gw-vpn.crt
600 ./gw-vpn.key
600 ./tls-crypt.key"
run "export-server refuses an existing directory" refuses export-server "$BUNDLE"

mkdir -m 700 "$PROFILES"
run "export-client writes the dev-01 profile" bash "$PKI_SH" "$CA_DIR" export-client dev-01 "$PROFILES/dev-01.ovpn"
run "export-client writes the admin-01 profile" bash "$PKI_SH" "$CA_DIR" export-client admin-01 "$PROFILES/admin-01.ovpn"
run "dev-01 profile has only the credentials of dev-01" profile_of dev-01
run "admin-01 profile has only the credentials of admin-01" profile_of admin-01
run "OpenVPN loads the dev-01 profile" openvpn_loads dev-01
run "export-client refuses the gw-vpn name" refuses export-client gw-vpn "$PROFILES/gw-vpn.ovpn"
run "export-client refuses a name that was not issued" refuses export-client ghost-01 "$PROFILES/ghost-01.ovpn"
run "export-client refuses names that are not plain identifiers" refuses export-client ../pki/private/ca.key "$PROFILES/ca.ovpn"
run "export-client refuses an existing file" refuses export-client dev-01 "$PROFILES/dev-01.ovpn"
run "Profiles are readable only by their owner and refused exports leave none" listing_is "$PROFILES" "700 .
600 ./admin-01.ovpn
600 ./dev-01.ovpn"
exit "$FAILED"
