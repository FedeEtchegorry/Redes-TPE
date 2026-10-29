#!/usr/bin/env bash
# Provisions k8s-node from a copy of the repository, as root:
#   k8s-node.sh SYSADMIN_SSH_KEY ETH0_MAC
# SYSADMIN_SSH_KEY is the public SSH key of the sysadmin profile (authorized in CU3).
# Installs Docker, enables SSH, and sets up static IP 10.10.10.5/16 with default route 10.10.0.1.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SYSADMIN_KEY=${1:?Usage: k8s-node.sh SYSADMIN_SSH_KEY ETH0_MAC}
ETH0_MAC=${2:?Missing MAC address of eth0}

ssh-keygen -l -f "$SYSADMIN_KEY" > /dev/null 2>&1 || fail "Invalid SSH public key"
check_mac "$ETH0_MAC"

# Authorize sysadmin SSH key for root administration (CU3)
install -d -m 700 "$DESTDIR/root/.ssh"
install -m 600 "$SYSADMIN_KEY" "$DESTDIR/root/.ssh/authorized_keys"

# Install Docker for running Kind cluster
install_packages docker.io curl
system systemctl enable docker

# Configure static network on the internal LAN
sed "s/@ETH0_MAC@/$ETH0_MAC/" "$ROOT/k8s/netplan.yaml" | install_netplan
echo "k8s-node is provisioned: run netplan apply or reboot to apply the network configuration."
