#!/usr/bin/env bash
# Provisions gw-sucursal from a copy of the repository, as root:
#   gw-sucursal.sh PROFILE ETH0_MAC ETH1_MAC
# PROFILE comes from scripts/pki.sh export-client gw-sucursal. gw-sucursal has no incoming
# WAN port: it is managed from its console. The interfaces get their names and the services start
# at the next boot.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROFILE=${1:?Usage: gw-sucursal.sh PROFILE ETH0_MAC ETH1_MAC}
ETH0_MAC=${2:?Missing MAC address of eth0}
ETH1_MAC=${3:?Missing MAC address of eth1}

# Only gw-sucursal has the branch LAN iroute in its CCD. Another profile would lose that route.
SUBJECT=$(sed -n '/^<cert>$/,/^<\/cert>$/{//!p}' "$PROFILE" | openssl x509 -noout -subject) ||
    fail "No certificate in the profile"
[[ $SUBJECT =~ CN\ ?=\ ?gw-sucursal$ ]] || fail "Not the profile of gw-sucursal: $SUBJECT"
check_macs "$ETH0_MAC" "$ETH1_MAC"

# The profile has the private key of gw-sucursal.
put 600 "$PROFILE" /etc/openvpn/client/the-store.conf
put 755 "$ROOT/branch/nftables/nftables.conf" /etc/nftables.conf
put 644 "$ROOT/branch/dnsmasq/the-store.conf" /etc/dnsmasq.d/the-store.conf
put 644 "$ROOT/branch/sysctl/the-store.conf" /etc/sysctl.d/90-the-store.conf

# After the configuration files, as on gw-vpn.
install_packages openvpn nftables dnsmasq

system systemctl enable nftables dnsmasq openvpn-client@the-store
gateway_netplan eth0 "$ETH0_MAC" 203.0.113.20/24 eth1 "$ETH1_MAC" 172.16.20.1/24 | install_netplan
echo "gw-sucursal is provisioned: reboot to rename the interfaces and start the services."
