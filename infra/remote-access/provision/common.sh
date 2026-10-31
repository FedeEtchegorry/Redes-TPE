# Functions of the provisioning scripts, which run as root on Ubuntu Server 24.04. With DESTDIR
# set, files are written under it and the commands that change the system are only printed:
# tests/provision.sh uses it.
umask 022
DESTDIR=${DESTDIR:-}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
    echo "$*" >&2
    exit 1
}

[[ -n $DESTDIR || $EUID == 0 ]] || fail "Run as root"

system() {
    if [[ -n $DESTDIR ]]; then
        echo "would run: $*"
    else
        "$@"
    fi
}

# put MODE SOURCE TARGET: installs SOURCE of the repository as TARGET.
put() {
    install -D -m "$1" "$2" "$DESTDIR$3"
}

check_mac() {
    [[ $1 =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || fail "Invalid MAC address (lowercase, with colons): $1"
    # A MAC address that no interface has leaves the machine without network after the reboot.
    [[ -n $DESTDIR ]] || grep -qx "$1" /sys/class/net/*/address || fail "No interface has the MAC address $1"
}

check_macs() {
    local mac
    local -A seen=()
    for mac in "$@"; do
        check_mac "$mac"
        [[ -z ${seen[$mac]+present} ]] || fail "Repeated MAC address: $mac"
        seen[$mac]=1
    done
}

# Validate the exported bundle before any destination file is written.
check_bundle() {
    local bundle=$1 file cert_public key_public crl_result last_update next_update now
    for file in ca.crt gw-vpn.crt gw-vpn.key tls-crypt.key crl.pem; do
        [[ -f "$bundle/$file" ]] || fail "Missing $file in the bundle"
    done
    # The bundle's CCD files replace the installed ones: with none, every client is locked out.
    compgen -G "$bundle/ccd/*" > /dev/null || fail "The bundle has no client in its ccd directory"
    openssl verify -CAfile "$bundle/ca.crt" -purpose sslserver "$bundle/gw-vpn.crt" > /dev/null ||
        fail "Invalid gateway server certificate"
    cert_public=$(openssl x509 -in "$bundle/gw-vpn.crt" -pubkey -noout) || fail "Cannot read certificate public key"
    key_public=$(openssl pkey -in "$bundle/gw-vpn.key" -passin pass: -pubout) || fail "Cannot read unencrypted gateway private key"
    [[ $cert_public == "$key_public" ]] || fail "Gateway key does not match its certificate"
    crl_result=$(openssl crl -in "$bundle/crl.pem" -CAfile "$bundle/ca.crt" -noout 2>&1) ||
        fail "Cannot read bundle CRL"
    [[ $crl_result == *"verify OK"* ]] || fail "Bundle CRL is not signed by its CA"
    last_update=$(date -d "$(openssl crl -in "$bundle/crl.pem" -noout -lastupdate | cut -d= -f2)" +%s) ||
        fail "Cannot read CRL lastUpdate"
    next_update=$(date -d "$(openssl crl -in "$bundle/crl.pem" -noout -nextupdate | cut -d= -f2)" +%s) ||
        fail "Cannot read CRL nextUpdate"
    now=$(date +%s)
    (( last_update <= now )) || fail "Bundle CRL is dated in the future: check the clocks"
    (( next_update > now )) || fail "Bundle CRL has expired"
}

# gateway_netplan NAME MAC ADDRESS...: names each interface by its MAC address, since nftables,
# OpenVPN and dnsmasq use eth0, eth1 and eth2, and nft accepts names that do not exist.
gateway_netplan() {
    printf 'network:\n  version: 2\n  ethernets:\n'
    while (( $# )); do
        printf '    %s:\n      match:\n        macaddress: "%s"\n      set-name: %s\n' "$1" "$2" "$1"
        printf '      dhcp4: false\n      addresses:\n        - %s\n' "$3"
        shift 3
    done
}

# install_netplan: installs standard input as the only netplan file. The others, such as the
# DHCP of cloud-init, are kept as .disabled, and cloud-init no longer writes the network.
install_netplan() {
    local file
    install -d -m 755 "$DESTDIR/etc/netplan" "$DESTDIR/etc/cloud/cloud.cfg.d"
    for file in "$DESTDIR"/etc/netplan/*.yaml; do
        [[ -e $file && $file != */90-the-store.yaml ]] || continue
        mv "$file" "$file.disabled"
    done
    (umask 077 && cat > "$DESTDIR/etc/netplan/90-the-store.yaml")
    printf 'network: {config: disabled}\n' > "$DESTDIR/etc/cloud/cloud.cfg.d/90-the-store.cfg"
}

install_packages() {
    system apt-get update
    # --force-confold: the package also ships /etc/nftables.conf, and dpkg would prompt for it.
    system env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold install --yes "$@"
}
