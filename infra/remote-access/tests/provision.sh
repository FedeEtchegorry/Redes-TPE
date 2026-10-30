#!/usr/bin/env bash
# Tests provision/*.sh with DESTDIR: checks the files they install, with their modes, and the
# commands they would run, then validates the files with sshd, visudo and netplan. Run with
# sudo; requires EasyRSA 3, OpenVPN, the OpenSSH server, sudo and netplan.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/run.sh"
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
GW_VPN=$WORK/gw-vpn
GW_SUCURSAL=$WORK/gw-sucursal
HOST_SUC=$WORK/host-suc
CA=$WORK/ca
K8S_NODE=$WORK/k8s-node
CLI_ADM=$WORK/cli-adm
CA_PKI=$WORK/pki-ca
OPENVPN_DIR=/etc/openvpn/server/the-store
MAC0=52:54:00:00:00:10
MAC1=52:54:00:00:00:11
MAC2=52:54:00:00:00:12
# What every host gets: its netplan file and the cloud-init setting that disables cloud-init's network.
BASE_LISTING="755 .
755 ./etc
755 ./etc/cloud
755 ./etc/cloud/cloud.cfg.d
644 ./etc/cloud/cloud.cfg.d/90-the-store.cfg
755 ./etc/netplan
600 ./etc/netplan/90-the-store.yaml"

pki() { env EASYRSA_PASSOUT=pass:test EASYRSA_PASSIN=pass:test bash "$ROOT/scripts/pki.sh" "$CA_PKI" "$@"; }

issue_certificates() {
    pki init && pki issue-server && pki issue-client dev-01 dev 10 &&
        pki issue-client gw-sucursal sucursal 30 && pki export-server "$WORK/bundle" &&
        pki export-client gw-sucursal "$WORK/gw-sucursal.ovpn" && pki export-client dev-01 "$WORK/dev-01.ovpn" &&
        ssh-keygen -q -t ed25519 -N '' -C ca -f "$WORK/ca-key"
}

# provision NAME ARGUMENT...: runs provision/NAME.sh with DESTDIR=WORK/NAME and keeps the
# commands it would run in WORK/NAME.commands.
provision() {
    local output
    output=$(DESTDIR=$WORK/$1 bash "$ROOT/provision/$1.sh" "${@:2}" 2>&1) || { echo "$output"; return 1; }
    echo "$output"
    sed -n 's/^would run: //p' <<< "$output" > "$WORK/$1.commands"
}

# refuses NAME ARGUMENT...: provision/NAME.sh fails and writes nothing.
refuses() {
    local destdir=$WORK/refused-$BASHPID
    ! DESTDIR=$destdir bash "$ROOT/provision/$1.sh" "${@:2}" && [[ ! -e $destdir ]]
}

# listing_is DIRECTORY LISTING: the permissions and paths under DIRECTORY are exactly LISTING.
listing_is() {
    local listing expected
    listing=$(cd "$1" && find . -printf '%m %p\n' | LC_ALL=C sort -k2)
    expected=$(LC_ALL=C sort -k2 <<< "$2")
    echo "$listing"
    [[ $listing == "$expected" ]]
}

# installs DIRECTORY SOURCE TARGET...: each TARGET under DIRECTORY is SOURCE of the repository.
installs() {
    local directory=$1
    shift
    while (( $# )); do
        cmp "$ROOT/$1" "$directory$2" || return 1
        shift 2
    done
}

bundle_installed() {
    local file
    for file in ca.crt gw-vpn.crt gw-vpn.key tls-crypt.key crl.pem ccd/dev-01 ccd/gw-sucursal; do
        cmp "$WORK/bundle/$file" "$GW_VPN$OPENVPN_DIR/$file" || return 1
    done
}

commands_are() {
    local commands
    commands=$(cat "$WORK/$1.commands")
    echo "$commands"
    [[ $commands == "$2" ]]
}

# sshd reads the drop-in of gw-vpn as its only configuration.
sshd_settings() {
    local settings sshd_bin
    sshd_bin=$(command -v sshd || echo /usr/sbin/sshd)
    mkdir -p /run/sshd
    ssh-keygen -q -t ed25519 -N '' -f "$WORK/host-key" &&
        printf 'Include %s/etc/ssh/sshd_config.d/*.conf\nHostKey %s/host-key\n' "$GW_VPN" "$WORK" > "$WORK/sshd_config" &&
        settings=$("$sshd_bin" -T -f "$WORK/sshd_config") || return 1
    grep -E '^(listenaddress|permitrootlogin|passwordauthentication|kbdinteractiveauthentication) ' <<< "$settings"
    grep -qx 'listenaddress 192.168.100.1:22' <<< "$settings" && grep -qx 'permitrootlogin no' <<< "$settings" &&
        grep -qx 'passwordauthentication no' <<< "$settings" &&
        grep -qx 'kbdinteractiveauthentication no' <<< "$settings"
}

# netplan_names ROOT NAME MAC ADDRESS: netplan names the interface with MAC as NAME and gives
# it ADDRESS. netplan matches the permanent MAC address, the one of the hardware.
netplan_names() {
    local link network
    link=$(cat "$1/run/systemd/network/10-netplan-$2.link") &&
        network=$(cat "$1/run/systemd/network/10-netplan-$2.network") || return 1
    echo "$link"
    echo "$network"
    grep -qix "PermanentMACAddress=$3" <<< "$link" && grep -qx "Name=$2" <<< "$link" && grep -qx "Address=$4" <<< "$network"
}

host_suc_routes_through_gw_sucursal() {
    local network
    network=$(cat "$HOST_SUC/run/systemd/network/10-netplan-eth0.network") || return 1
    echo "$network"
    grep -qx 'Gateway=172.16.20.1' <<< "$network" && grep -qx 'DNS=172.16.20.1' <<< "$network"
}

k8s_node_routes_through_gw_vpn() {
    local network
    network=$(cat "$K8S_NODE/run/systemd/network/10-netplan-eth0.network") || return 1
    echo "$network"
    grep -qx 'Gateway=10.10.0.1' <<< "$network"
}

cli_adm_routes_through_wan_gateway() {
    local network
    network=$(cat "$CLI_ADM/run/systemd/network/10-netplan-eth0.network") || return 1
    echo "$network"
    grep -qx 'Gateway=203.0.113.1' <<< "$network"
}

run "pki.sh issues the certificates, the bundle and the profiles" issue_certificates
echo "not a key" > "$WORK/not-a-key.pub"
mkdir "$WORK/empty-bundle"

# gw-vpn
run "gw-vpn refuses an incomplete bundle" refuses gw-vpn "$WORK/empty-bundle" "$WORK/ca-key.pub" "$MAC0" "$MAC1" "$MAC2"
run "gw-vpn refuses an invalid SSH key" refuses gw-vpn "$WORK/bundle" "$WORK/not-a-key.pub" "$MAC0" "$MAC1" "$MAC2"
run "gw-vpn refuses an invalid MAC address" refuses gw-vpn "$WORK/bundle" "$WORK/ca-key.pub" "$MAC0" "$MAC1" 52:54:00:00:00:1Z
run "gw-vpn refuses repeated MAC addresses" refuses gw-vpn "$WORK/bundle" "$WORK/ca-key.pub" "$MAC0" "$MAC0" "$MAC2"

cp -a "$WORK/bundle" "$WORK/no-clients-bundle"
rm "$WORK/no-clients-bundle/ccd/"*
run "gw-vpn refuses a bundle without clients, which would lock every client out" \
    refuses gw-vpn "$WORK/no-clients-bundle" "$WORK/ca-key.pub" "$MAC0" "$MAC1" "$MAC2"

# Cryptographically incorrect but complete bundles must fail before writing any destination.
cp -a "$WORK/bundle" "$WORK/client-certificate-bundle"
cp "$CA_PKI/pki/issued/dev-01.crt" "$WORK/client-certificate-bundle/gw-vpn.crt"
run "gw-vpn refuses a client certificate as its server certificate" \
    refuses gw-vpn "$WORK/client-certificate-bundle" "$WORK/ca-key.pub" "$MAC0" "$MAC1" "$MAC2"
cp -a "$WORK/bundle" "$WORK/mismatched-key-bundle"
cp "$CA_PKI/pki/private/dev-01.key" "$WORK/mismatched-key-bundle/gw-vpn.key"
run "gw-vpn refuses a private key that does not match its certificate" \
    refuses gw-vpn "$WORK/mismatched-key-bundle" "$WORK/ca-key.pub" "$MAC0" "$MAC1" "$MAC2"
env EASYRSA_PASSOUT=pass:test EASYRSA_PASSIN=pass:test bash "$ROOT/scripts/pki.sh" "$WORK/other-ca" init > /dev/null 2>&1
cp -a "$WORK/bundle" "$WORK/other-crl-bundle"
cp "$WORK/other-ca/pki/crl.pem" "$WORK/other-crl-bundle/crl.pem"
run "gw-vpn refuses a CRL signed by another CA" \
    refuses gw-vpn "$WORK/other-crl-bundle" "$WORK/ca-key.pub" "$MAC0" "$MAC1" "$MAC2"
mkdir "$WORK/clock"
cat > "$WORK/clock/date" <<'EOF'
#!/bin/bash
if [[ $# == 1 && $1 == +%s ]]; then
    echo "$THE_STORE_TEST_NOW"
else
    exec /usr/bin/date "$@"
fi
EOF
chmod +x "$WORK/clock/date"
refuses_at_time() { THE_STORE_TEST_NOW=$1 PATH="$WORK/clock:$PATH" refuses "${@:2}"; }
run "gw-vpn refuses a bundle CRL dated in the future" \
    refuses_at_time 0 gw-vpn "$WORK/bundle" "$WORK/ca-key.pub" "$MAC0" "$MAC1" "$MAC2"
CRL_EXPIRY=$(date -d "$(openssl crl -in "$WORK/bundle/crl.pem" -noout -nextupdate | cut -d= -f2)" +%s)
run "gw-vpn refuses an expired bundle CRL" \
    refuses_at_time "$((CRL_EXPIRY + 1))" gw-vpn "$WORK/bundle" "$WORK/ca-key.pub" "$MAC0" "$MAC1" "$MAC2"
run "gw-vpn is provisioned" provision gw-vpn "$WORK/bundle" "$WORK/ca-key.pub" "$MAC0" "$MAC1" "$MAC2"
run "gw-vpn gets only its files, with private keys readable by root only" listing_is "$GW_VPN" "$BASE_LISTING
755 ./etc/dnsmasq.d
644 ./etc/dnsmasq.d/the-store.conf
755 ./etc/nftables.conf
755 ./etc/openvpn
755 ./etc/openvpn/server
644 ./etc/openvpn/server/the-store.conf
755 ./etc/openvpn/server/the-store
644 ./etc/openvpn/server/the-store/ca.crt
755 ./etc/openvpn/server/the-store/ccd
644 ./etc/openvpn/server/the-store/ccd/dev-01
644 ./etc/openvpn/server/the-store/ccd/gw-sucursal
644 ./etc/openvpn/server/the-store/crl.pem
644 ./etc/openvpn/server/the-store/gw-vpn.crt
600 ./etc/openvpn/server/the-store/gw-vpn.key
600 ./etc/openvpn/server/the-store/tls-crypt.key
755 ./etc/ssh
755 ./etc/ssh/sshd_config.d
644 ./etc/ssh/sshd_config.d/10-the-store.conf
755 ./etc/sudoers.d
440 ./etc/sudoers.d/the-store-crl
755 ./etc/sysctl.d
644 ./etc/sysctl.d/90-the-store.conf
755 ./home
755 ./home/the-store-crl
700 ./home/the-store-crl/.ssh
600 ./home/the-store-crl/.ssh/authorized_keys
755 ./usr
755 ./usr/local
755 ./usr/local/sbin
755 ./usr/local/sbin/the-store-update-crl"
run "gw-vpn gets the files of the repository" installs "$GW_VPN" \
    gateway/openvpn/server.conf /etc/openvpn/server/the-store.conf \
    gateway/openvpn/update-crl.sh /usr/local/sbin/the-store-update-crl \
    gateway/nftables/nftables.conf /etc/nftables.conf \
    gateway/dnsmasq/the-store.conf /etc/dnsmasq.d/the-store.conf \
    gateway/sysctl/the-store.conf /etc/sysctl.d/90-the-store.conf \
    gateway/ssh/the-store.conf /etc/ssh/sshd_config.d/10-the-store.conf \
    gateway/sudo/the-store-crl /etc/sudoers.d/the-store-crl
run "gw-vpn gets the bundle" bundle_installed
run "The CA can log in as the-store-crl with its key" \
    cmp "$WORK/ca-key.pub" "$GW_VPN/home/the-store-crl/.ssh/authorized_keys"
run "gw-vpn installs its packages, creates the-store-crl and enables its services" commands_are gw-vpn \
    "apt-get update
env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold install --yes openvpn nftables dnsmasq socat
useradd --system --create-home --shell /bin/bash the-store-crl
chown -R the-store-crl: /home/the-store-crl/.ssh
systemctl enable nftables dnsmasq openvpn-server@the-store"
run "sshd listens only on the management network, with keys and without root" sshd_settings
run "sudo accepts the rule of the-store-crl" visudo -cf "$GW_VPN/etc/sudoers.d/the-store-crl"
run "netplan accepts the gw-vpn file" netplan generate --root-dir "$GW_VPN"
run "netplan names eth0 of gw-vpn, on the untrusted segment" netplan_names "$GW_VPN" eth0 "$MAC0" 203.0.113.10/24
run "netplan names eth1 of gw-vpn, on the LAN" netplan_names "$GW_VPN" eth1 "$MAC1" 10.10.0.1/16
run "netplan names eth2 of gw-vpn, on the management network" netplan_names "$GW_VPN" eth2 "$MAC2" 192.168.100.1/24

# A new bundle after a revocation: its CCD files replace the installed ones, its CRL does not.
new_bundle_after_revocation() { pki revoke dev-01 && pki export-server "$WORK/bundle-2"; }
run "pki.sh revokes dev-01 and exports a new bundle" new_bundle_after_revocation
run "gw-vpn is provisioned again with a new bundle" provision gw-vpn "$WORK/bundle-2" "$WORK/ca-key.pub" "$MAC0" "$MAC1" "$MAC2"
run "The CCD files are those of the new bundle" bash -c '[[ $(ls "$1") == gw-sucursal ]]' _ "$GW_VPN$OPENVPN_DIR/ccd"
run "The installed CRL is kept, since only publish-crl replaces it" \
    bash -c 'cmp "$1" "$3" && ! cmp -s "$2" "$3"' _ "$WORK/bundle/crl.pem" "$WORK/bundle-2/crl.pem" "$GW_VPN$OPENVPN_DIR/crl.pem"

# gw-sucursal
run "gw-sucursal refuses the profile of another client" refuses gw-sucursal "$WORK/dev-01.ovpn" "$MAC0" "$MAC1"
run "gw-sucursal refuses an invalid MAC address" refuses gw-sucursal "$WORK/gw-sucursal.ovpn" "$MAC0" 52:54:00:00:00
run "gw-sucursal refuses repeated MAC addresses" refuses gw-sucursal "$WORK/gw-sucursal.ovpn" "$MAC0" "$MAC0"
run "gw-sucursal is provisioned" provision gw-sucursal "$WORK/gw-sucursal.ovpn" "$MAC0" "$MAC1"
run "gw-sucursal gets only its files, with the profile readable by root only" listing_is "$GW_SUCURSAL" "$BASE_LISTING
755 ./etc/dnsmasq.d
644 ./etc/dnsmasq.d/the-store.conf
755 ./etc/nftables.conf
755 ./etc/openvpn
755 ./etc/openvpn/client
600 ./etc/openvpn/client/the-store.conf
755 ./etc/sysctl.d
644 ./etc/sysctl.d/90-the-store.conf"
run "gw-sucursal gets the files of the repository and its profile" installs "$GW_SUCURSAL" \
    branch/nftables/nftables.conf /etc/nftables.conf \
    branch/dnsmasq/the-store.conf /etc/dnsmasq.d/the-store.conf \
    branch/sysctl/the-store.conf /etc/sysctl.d/90-the-store.conf
run "gw-sucursal connects with the gw-sucursal profile" \
    cmp "$WORK/gw-sucursal.ovpn" "$GW_SUCURSAL/etc/openvpn/client/the-store.conf"
run "gw-sucursal installs its packages and enables its services" commands_are gw-sucursal \
    "apt-get update
env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold install --yes openvpn nftables dnsmasq
systemctl enable nftables dnsmasq openvpn-client@the-store"
run "netplan accepts the gw-sucursal file" netplan generate --root-dir "$GW_SUCURSAL"
run "netplan names eth0 of gw-sucursal, on the untrusted segment" \
    netplan_names "$GW_SUCURSAL" eth0 "$MAC0" 203.0.113.20/24
run "netplan names eth1 of gw-sucursal, on the branch LAN" netplan_names "$GW_SUCURSAL" eth1 "$MAC1" 172.16.20.1/24

# host-suc, with the DHCP file of cloud-init.
mkdir -p "$HOST_SUC/etc/netplan"
(umask 077 && printf 'network:\n  version: 2\n' > "$HOST_SUC/etc/netplan/50-cloud-init.yaml")
run "host-suc refuses an invalid MAC address" refuses host-suc 52:54:00:00:00:1A
run "host-suc is provisioned" provision host-suc "$MAC0"
run "host-suc only gets its netplan file, and the one of cloud-init is disabled" listing_is "$HOST_SUC" "$BASE_LISTING
600 ./etc/netplan/50-cloud-init.yaml.disabled"
run "host-suc installs no package and enables no service" commands_are host-suc ""
run "netplan accepts the host-suc file" netplan generate --root-dir "$HOST_SUC"
run "netplan names eth0 of host-suc, on the branch LAN" netplan_names "$HOST_SUC" eth0 "$MAC0" 172.16.20.10/24
run "host-suc uses gw-sucursal as gateway and DNS server" host_suc_routes_through_gw_sucursal

# ca
run "ca refuses an invalid SSH private key" refuses ca "$WORK/not-a-key.pub" "$MAC0"
run "ca refuses an invalid MAC address" refuses ca "$WORK/ca-key" 52:54:00:00:00:1A
run "ca is provisioned" provision ca "$WORK/ca-key" "$MAC0"
run "ca gets only its files, with the private key readable by root only" listing_is "$CA" "$BASE_LISTING
755 ./root
700 ./root/.ssh
600 ./root/.ssh/id_ed25519
644 ./root/.ssh/id_ed25519.pub"
run "ca installs its private key and public key" bash -c 'cmp "$1" "$2/root/.ssh/id_ed25519" && cmp "$1.pub" "$2/root/.ssh/id_ed25519.pub"' _ "$WORK/ca-key" "$CA"
run "ca installs its packages" commands_are ca \
    "apt-get update
env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold install --yes easy-rsa openvpn openssh-client"
run "netplan accepts the ca file" netplan generate --root-dir "$CA"
run "netplan names eth0 of ca, on the management network" netplan_names "$CA" eth0 "$MAC0" 192.168.100.20/24

# k8s-node
run "k8s-node refuses an invalid SSH public key" refuses k8s-node "$WORK/not-a-key.pub" "$MAC0"
run "k8s-node refuses an invalid MAC address" refuses k8s-node "$WORK/ca-key.pub" 52:54:00:00:00:1A
run "k8s-node is provisioned" provision k8s-node "$WORK/ca-key.pub" "$MAC0"
run "k8s-node gets only its files, with authorized_keys readable by root only" listing_is "$K8S_NODE" "$BASE_LISTING
755 ./root
700 ./root/.ssh
600 ./root/.ssh/authorized_keys"
run "k8s-node installs the sysadmin authorized key" cmp "$WORK/ca-key.pub" "$K8S_NODE/root/.ssh/authorized_keys"
run "k8s-node installs its packages and enables docker" commands_are k8s-node \
    "apt-get update
env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold install --yes docker.io curl
systemctl enable docker"
run "netplan accepts the k8s-node file" netplan generate --root-dir "$K8S_NODE"
run "netplan names eth0 of k8s-node, on the internal LAN" netplan_names "$K8S_NODE" eth0 "$MAC0" 10.10.10.5/16
run "k8s-node routes through gw-vpn" k8s_node_routes_through_gw_vpn

# cli-adm
pki issue-client admin-01 sysadmin 20 && pki export-client admin-01 "$WORK/admin-01.ovpn"
run "cli-adm refuses an invalid profile" refuses cli-adm "$WORK/not-a-key.pub" "$MAC0"
run "cli-adm refuses an invalid MAC address" refuses cli-adm "$WORK/admin-01.ovpn" 52:54:00:00:00:1A
run "cli-adm is provisioned" provision cli-adm "$WORK/admin-01.ovpn" "$MAC0"
run "cli-adm gets only its files, with the profile readable by root only" listing_is "$CLI_ADM" "$BASE_LISTING
755 ./etc/openvpn
755 ./etc/openvpn/client
600 ./etc/openvpn/client/the-store.conf"
run "cli-adm installs the openvpn client profile" cmp "$WORK/admin-01.ovpn" "$CLI_ADM/etc/openvpn/client/the-store.conf"
run "cli-adm installs its packages and enables openvpn" commands_are cli-adm \
    "apt-get update
env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold install --yes openvpn nmap curl socat
systemctl enable openvpn-client@the-store"
run "netplan accepts the cli-adm file" netplan generate --root-dir "$CLI_ADM"
run "netplan names eth0 of cli-adm, on the untrusted segment" netplan_names "$CLI_ADM" eth0 "$MAC0" 203.0.113.51/24
run "cli-adm routes through simulated Internet gateway" cli_adm_routes_through_wan_gateway

exit "$FAILED"
