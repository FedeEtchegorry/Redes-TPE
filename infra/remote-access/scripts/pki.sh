#!/usr/bin/env bash
# VPN certificate authority, run on the CA VM (192.168.100.20). EasyRSA asks for the
# CA key passphrase, or reads it from EASYRSA_PASSOUT (init) and EASYRSA_PASSIN.
set -euo pipefail
umask 077

CA_DIR=${1:?Usage: pki.sh CA_DIRECTORY init|issue-server|issue-client|export-server|export-client [arguments]}
ACTION=${2:?Missing action}
shift 2
mkdir -p "$CA_DIR"
CA_DIR=$(cd "$CA_DIR" && pwd)
export EASYRSA_PKI="$CA_DIR/pki"
export EASYRSA_ALGO=${EASYRSA_ALGO:-ec}
export EASYRSA_CURVE=${EASYRSA_CURVE:-prime256v1}
export EASYRSA_CRL_DAYS=${EASYRSA_CRL_DAYS:-30}
export EASYRSA_CERT_EXPIRE=${EASYRSA_CERT_EXPIRE:-365}
EASYRSA_BIN=${EASYRSA_BIN:-/usr/share/easy-rsa/easyrsa}
CLIENT_CONF=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/clients/client.conf

fail() {
    echo "$*" >&2
    exit 1
}

# The name is also the CCD file name. DEFAULT is the CCD file OpenVPN applies to
# clients without their own file, and gw-vpn is the server certificate.
check_name() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || fail "Invalid certificate name"
    [[ "$1" != DEFAULT && "$1" != gw-vpn ]] || fail "Reserved certificate name"
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
    issue-client)
        CLIENT=${1:?Missing certificate name}
        ROLE=${2:?Missing role: dev|sysadmin|sucursal}
        OCTET=${3:?Missing last tunnel IP octet}
        check_name "$CLIENT"
        case "$ROLE" in
            dev) [[ "$OCTET" == 1[0-9] ]] || fail "dev uses .10-.19" ;;
            sysadmin) [[ "$OCTET" == 2[0-9] ]] || fail "sysadmin uses .20-.29" ;;
            sucursal) [[ "$OCTET" == 30 && "$CLIENT" == gw-sucursal ]] || fail "sucursal requires gw-sucursal at .30" ;;
            *) fail "Unknown role" ;;
        esac
        [[ "$CLIENT" != gw-sucursal || "$ROLE" == sucursal ]] || fail "gw-sucursal is reserved for the branch"
        mkdir -p "$CA_DIR/ccd"
        if grep -RqE "^ifconfig-push 10\\.8\\.0\\.$OCTET " "$CA_DIR/ccd"; then
            fail "Tunnel IP is already assigned"
        fi
        # Client keys have no passphrase either: gw-sucursal connects unattended and the
        # profiles are handed out over an out-of-band channel.
        env -u EASYRSA_PASSOUT "$EASYRSA_BIN" --batch build-client-full "$CLIENT" nopass
        # Fixed tunnel IP within the role range, and the only route the client gets:
        # the node.
        printf 'ifconfig-push 10.8.0.%s 255.255.255.0\npush "route 10.10.10.5 255.255.255.255"\n' \
            "$OCTET" > "$CA_DIR/ccd/$CLIENT"
        if [[ "$ROLE" == sucursal ]]; then
            # Traffic to the branch LAN is sent to the gw-sucursal tunnel.
            printf 'iroute 172.16.20.0 255.255.255.0\n' >> "$CA_DIR/ccd/$CLIENT"
        fi
        ;;
    export-server)
        # Files gw-vpn needs, in a new directory to copy over the management network.
        # The CA key stays in the CA.
        DEST=${1:?Missing output directory}
        [[ ! -e "$DEST" ]] || fail "Output directory already exists"
        install -d -m 700 "$DEST"
        install -m 644 "$EASYRSA_PKI/ca.crt" "$EASYRSA_PKI/issued/gw-vpn.crt" "$EASYRSA_PKI/crl.pem" "$DEST/"
        install -m 600 "$EASYRSA_PKI/private/gw-vpn.key" "$CA_DIR/tls-crypt.key" "$DEST/"
        install -d -m 755 "$DEST/ccd"
        for CLIENT_FILE in "$CA_DIR/ccd/"*; do
            [[ -f "$CLIENT_FILE" ]] || continue
            install -m 644 "$CLIENT_FILE" "$DEST/ccd/"
        done
        ;;
    export-client)
        # Unified profile for OpenVPN GUI and the openvpn CLI: client.conf followed by the
        # CA, the client certificate and key, and the tls-crypt key.
        CLIENT=${1:?Missing certificate name}
        DEST=${2:?Missing output profile path}
        check_name "$CLIENT"
        [[ -f "$CA_DIR/ccd/$CLIENT" ]] || fail "Client was not issued with issue-client"
        [[ ! -e "$DEST" ]] || fail "Output file already exists"
        {
            cat "$CLIENT_CONF"
            printf '\n<ca>\n'
            cat "$EASYRSA_PKI/ca.crt"
            printf '</ca>\n<cert>\n'
            # Only the PEM block, without the text dump EasyRSA writes before it.
            openssl x509 -in "$EASYRSA_PKI/issued/$CLIENT.crt"
            printf '</cert>\n<key>\n'
            cat "$EASYRSA_PKI/private/$CLIENT.key"
            printf '</key>\n<tls-crypt>\n'
            cat "$CA_DIR/tls-crypt.key"
            printf '</tls-crypt>\n'
        } > "$DEST"
        ;;
    *) fail "Unknown action: $ACTION" ;;
esac
