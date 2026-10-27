#!/usr/bin/env bash
# Provisions host-suc, as root: host-suc.sh ETH0_MAC. It only gets its network configuration:
# no VPN client, gw-sucursal is its gateway and DNS server.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ETH0_MAC=${1:?Usage: host-suc.sh ETH0_MAC}
check_mac "$ETH0_MAC"

sed "s/@ETH0_MAC@/$ETH0_MAC/" "$ROOT/branch/host-suc/netplan.yaml" | install_netplan
echo "host-suc is provisioned: run netplan apply or reboot."
