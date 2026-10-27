#!/usr/bin/env bash
# Provisions gw-vpn from a copy of the repository, as root:
#   gw-vpn.sh BUNDLE_DIRECTORY CA_SSH_PUBLIC_KEY ETH0_MAC ETH1_MAC ETH2_MAC
# BUNDLE_DIRECTORY comes from scripts/pki.sh export-server. The CA publishes the CRL as the
# the-store-crl user, with CA_SSH_PUBLIC_KEY. The interfaces get their names and the services
# start at the next boot.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BUNDLE=${1:?Usage: gw-vpn.sh BUNDLE_DIRECTORY CA_SSH_PUBLIC_KEY ETH0_MAC ETH1_MAC ETH2_MAC}
CA_KEY=${2:?Missing SSH public key of the CA}
ETH0_MAC=${3:?Missing MAC address of eth0}
ETH1_MAC=${4:?Missing MAC address of eth1}
ETH2_MAC=${5:?Missing MAC address of eth2}
OPENVPN_DIR=/etc/openvpn/server/the-store
CRL_USER=the-store-crl

# Everything is checked before anything changes.
for FILE in ca.crt gw-vpn.crt gw-vpn.key tls-crypt.key crl.pem; do
    [[ -f "$BUNDLE/$FILE" ]] || fail "Missing $FILE in the bundle"
done
ssh-keygen -l -f "$CA_KEY" > /dev/null || fail "Invalid SSH public key"
for MAC in "$ETH0_MAC" "$ETH1_MAC" "$ETH2_MAC"; do
    check_mac "$MAC"
done

# Same modes as in the bundle: only the keys are private, since crl.pem and the CCD files are
# read as the nobody user.
install -d -m 755 "$DESTDIR$OPENVPN_DIR" "$DESTDIR$OPENVPN_DIR/ccd"
install -m 644 "$BUNDLE/ca.crt" "$BUNDLE/gw-vpn.crt" "$DESTDIR$OPENVPN_DIR/"
install -m 600 "$BUNDLE/gw-vpn.key" "$BUNDLE/tls-crypt.key" "$DESTDIR$OPENVPN_DIR/"
# Later CRLs only come from publish-crl, which refuses older ones: an older bundle must not
# undo a revocation.
[[ -e "$DESTDIR$OPENVPN_DIR/crl.pem" ]] || install -m 644 "$BUNDLE/crl.pem" "$DESTDIR$OPENVPN_DIR/"
# The CCD files are replaced: a client left out of the bundle has no tunnel IP (ccd-exclusive).
rm -f "$DESTDIR$OPENVPN_DIR/ccd/"*
for FILE in "$BUNDLE/ccd/"*; do
    [[ -f "$FILE" ]] || continue
    install -m 644 "$FILE" "$DESTDIR$OPENVPN_DIR/ccd/"
done

put 644 "$ROOT/gateway/openvpn/server.conf" /etc/openvpn/server/the-store.conf
put 755 "$ROOT/gateway/openvpn/update-crl.sh" /usr/local/sbin/the-store-update-crl
put 755 "$ROOT/gateway/nftables/nftables.conf" /etc/nftables.conf
put 644 "$ROOT/gateway/dnsmasq/the-store.conf" /etc/dnsmasq.d/the-store.conf
put 644 "$ROOT/gateway/sysctl/the-store.conf" /etc/sysctl.d/90-the-store.conf
put 644 "$ROOT/gateway/ssh/the-store.conf" /etc/ssh/sshd_config.d/10-the-store.conf
put 440 "$ROOT/gateway/sudo/the-store-crl" /etc/sudoers.d/the-store-crl

# After the configuration files: dnsmasq starts when installed, and its default configuration
# would take port 53 from systemd-resolved.
install_packages openvpn nftables dnsmasq socat

id "$CRL_USER" > /dev/null 2>&1 || system useradd --system --create-home --shell /bin/bash "$CRL_USER"
install -d -m 700 "$DESTDIR/home/$CRL_USER/.ssh"
install -m 600 "$CA_KEY" "$DESTDIR/home/$CRL_USER/.ssh/authorized_keys"
system chown -R "$CRL_USER:" "/home/$CRL_USER/.ssh"

system systemctl enable nftables dnsmasq openvpn-server@the-store
gateway_netplan eth0 "$ETH0_MAC" 203.0.113.10/24 eth1 "$ETH1_MAC" 10.10.0.1/16 \
    eth2 "$ETH2_MAC" 192.168.100.1/24 | install_netplan
echo "gw-vpn is provisioned: reboot to rename the interfaces and start the services."
