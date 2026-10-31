#!/usr/bin/env bash
# Provisions k8s-node from a copy of the repository, as root:
#   k8s-node.sh SYSADMIN_SSH_KEY ETH0_MAC
# SYSADMIN_SSH_KEY contains one public SSH key of the sysadmin profile (authorized in CU3).
# Installs Docker. The OpenSSH server must already be installed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SYSADMIN_KEY=${1:?Usage: k8s-node.sh SYSADMIN_SSH_KEY ETH0_MAC}
ETH0_MAC=${2:?Missing MAC address of eth0}

ssh-keygen -l -f "$SYSADMIN_KEY" > /dev/null 2>&1 || fail "Invalid SSH public key"
KEY=$(cat "$SYSADMIN_KEY")
[[ $KEY != *$'\n'* ]] || fail "Provide one SSH public key per file"
check_mac "$ETH0_MAC"

# Authorize sysadmin SSH key for root administration (CU3)
install -d -m 700 "$DESTDIR/root/.ssh"
AUTHORIZED_KEYS=$DESTDIR/root/.ssh/authorized_keys
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
grep -qxF -- "$KEY" "$AUTHORIZED_KEYS" || printf '\n%s\n' "$KEY" >> "$AUTHORIZED_KEYS"

# Install Docker for running Kind cluster
install_packages docker.io curl
system systemctl enable docker

# Configure static network on the internal LAN
sed "s/@ETH0_MAC@/$ETH0_MAC/" "$ROOT/k8s/netplan.yaml" | install_netplan
echo "k8s-node is provisioned: run netplan apply or reboot to apply the network configuration."
