#!/usr/bin/env bash
# VPN certificate authority, run on the CA VM (192.168.100.20). EasyRSA asks for the
# CA key passphrase, or reads it from EASYRSA_PASSOUT (init) and EASYRSA_PASSIN.
set -euo pipefail
umask 077

CA_DIR=${1:?Usage: pki.sh CA_DIRECTORY init|issue-server}
ACTION=${2:?Missing action}
mkdir -p "$CA_DIR"
CA_DIR=$(cd "$CA_DIR" && pwd)
export EASYRSA_PKI="$CA_DIR/pki"
export EASYRSA_ALGO=${EASYRSA_ALGO:-ec}
export EASYRSA_CURVE=${EASYRSA_CURVE:-prime256v1}
export EASYRSA_CRL_DAYS=${EASYRSA_CRL_DAYS:-30}
export EASYRSA_CERT_EXPIRE=${EASYRSA_CERT_EXPIRE:-365}
EASYRSA_BIN=${EASYRSA_BIN:-/usr/share/easy-rsa/easyrsa}

fail() {
    echo "$*" >&2
    exit 1
}

case "$ACTION" in
    init)
        [[ ! -e "$EASYRSA_PKI" ]] || fail "PKI already exists; refusing to overwrite it"
        "$EASYRSA_BIN" --batch init-pki
        EASYRSA_REQ_CN="The Store VPN CA" "$EASYRSA_BIN" --batch build-ca
        openvpn --genkey secret "$CA_DIR/tls-crypt.key"
        "$EASYRSA_BIN" --batch gen-crl
        ;;
    issue-server)
        # The gateway key has no passphrase so that OpenVPN starts unattended.
        env -u EASYRSA_PASSOUT "$EASYRSA_BIN" --batch build-server-full gw-vpn nopass
        ;;
    *) fail "Unknown action: $ACTION" ;;
esac
