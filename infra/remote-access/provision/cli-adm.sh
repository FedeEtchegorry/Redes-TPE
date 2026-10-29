#!/usr/bin/env bash
# Provisions cli-adm from a copy of the repository, as root:
#   cli-adm.sh PROFILE ETH0_MAC
# PROFILE comes from scripts/pki.sh export-client admin-01. Installs OpenVPN, nmap, curl,
# socat, sets up the OpenVPN client profile, and configures static IP on the untrusted segment.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROFILE=${1:?Usage: cli-adm.sh PROFILE ETH0_MAC}
ETH0_MAC=${2:?Missing MAC address of eth0}

SUBJECT=$(sed -n '/^<cert>$/,/^<\/cert>$/{//!p}' "$PROFILE" | openssl x509 -noout -subject) ||
    fail "No certificate in the profile"
check_mac "$ETH0_MAC"

# Install OpenVPN client profile
put 600 "$PROFILE" /etc/openvpn/client/the-store.conf

# Install packages required for administration, testing and scanning (CU1, CU3)
install_packages openvpn nmap curl socat

# Enable OpenVPN client service
system systemctl enable openvpn-client@the-store

# Configure static network on the untrusted segment
sed "s/@ETH0_MAC@/$ETH0_MAC/" "$ROOT/clients/cli-adm/netplan.yaml" | install_netplan
echo "cli-adm is provisioned: run netplan apply or reboot to apply the network configuration."
