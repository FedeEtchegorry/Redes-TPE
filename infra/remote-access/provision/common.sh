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
    system env DEBIAN_FRONTEND=noninteractive apt-get install --yes "$@"
}
