#!/usr/bin/env bash
# Provisions the CA VM (192.168.100.20) from a copy of the repository, as root:
#   ca.sh CA_SSH_PRIVATE_KEY ETH0_MAC
# CA_SSH_PRIVATE_KEY is the private SSH key used to publish the CRL to gw-vpn as the-store-crl.
# The interface gets its name and static IP on the isolated management network.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

KEY=${1:?Usage: ca.sh CA_SSH_PRIVATE_KEY ETH0_MAC}
ETH0_MAC=${2:?Missing MAC address of eth0}

ssh-keygen -y -f "$KEY" > /dev/null 2>&1 || fail "Invalid SSH private key"
check_mac "$ETH0_MAC"

# Install private key to publish CRL over the management network
install -d -m 700 "$DESTDIR/root/.ssh"
install -m 600 "$KEY" "$DESTDIR/root/.ssh/id_ed25519"
ssh-keygen -y -f "$KEY" > "$DESTDIR/root/.ssh/id_ed25519.pub"
chmod 644 "$DESTDIR/root/.ssh/id_ed25519.pub"

# Install packages required for PKI operations and CRL publishing
install_packages easy-rsa openvpn openssh-client

# Configure static network on the management subnet
gateway_netplan eth0 "$ETH0_MAC" 192.168.100.20/24 | install_netplan
echo "ca is provisioned: run netplan apply or reboot to apply the network configuration."
