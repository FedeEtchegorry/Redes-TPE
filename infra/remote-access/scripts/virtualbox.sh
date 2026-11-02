#!/usr/bin/env bash
# VirtualBox lab of the POC:
#   virtualbox.sh networks | base ISO | clones | macs | offline | online | snapshot | restore
# The host is the Windows dev client (203.0.113.50). On a Linux host, /etc/vbox/networks.conf
# must allow the ranges: "* 203.0.113.0/24 192.168.100.0/24".
set -euo pipefail

ACTION=${1:?Usage: virtualbox.sh networks|base ISO|clones|macs|offline|online|snapshot|restore}
VBOXMANAGE=${VBOXMANAGE:-$(command -v VBoxManage || echo "/c/Program Files/Oracle/VirtualBox/VBoxManage.exe")}
BASE=the-store-base
SNAPSHOT=installed
DEMO=demo
WAN_HOST_IP=203.0.113.50
MGMT_HOST_IP=192.168.100.254

# NAME MEMORY_MB CPUS NETWORK... : NETWORK n is ethN-1, in the order of provision/NAME.sh.
VMS=(
    "gw-vpn 1024 1 wan lan mgmt"
    "k8s-node 6144 4 lan"
    "ca 1024 1 mgmt"
    "cli-adm 1024 1 wan"
    "gw-sucursal 1024 1 wan branch"
    "host-suc 1024 1 branch"
)

fail() {
    echo "$*" >&2
    exit 1
}

vbox() { "$VBOXMANAGE" "$@" | tr -d '\r'; }

exists() { vbox showvminfo "$1" > /dev/null 2>&1; }

has_snapshot() { vbox showvminfo "$1" --machinereadable | grep -q "^SnapshotName.*=\"$2\""; }

# mac VM NIC: 08:00:27 (VirtualBox) : VM : NIC, fixed so that provisioning knows it in advance.
mac() { printf '08:00:27:00:%02x:%02x' "$1" "$2"; }

hostonly_name() {
    vbox list hostonlyifs | awk -v ip="$1" '/^Name:/ { sub(/^Name: +/, ""); name = $0 } /^IPAddress:/ && $2 == ip { print name }'
}

# hostonly IP: the host-only interface where the host has IP, created if missing, without DHCP.
hostonly() {
    local name
    name=$(hostonly_name "$1")
    if [[ -z $name ]]; then
        name=$(vbox hostonlyif create | sed -n "s/.*Interface '\(.*\)' was successfully created.*/\1/p")
        [[ -n $name ]] || fail "Cannot create a host-only interface"
        vbox hostonlyif ipconfig "$name" --ip "$1" --netmask 255.255.255.0
    fi
    vbox dhcpserver remove --interface="$name" > /dev/null 2>&1 || true
    echo "$name"
}

# attach NIC NETWORK: adds the modifyvm options of NIC to OPTIONS.
attach() {
    case "$2" in
        wan) OPTIONS+=(--nic"$1" hostonly --hostonlyadapter"$1" "$WAN_IF") ;;
        mgmt) OPTIONS+=(--nic"$1" hostonly --hostonlyadapter"$1" "$MGMT_IF") ;;
        lan) OPTIONS+=(--nic"$1" intnet --intnet"$1" the-store-lan) ;;
        branch) OPTIONS+=(--nic"$1" intnet --intnet"$1" the-store-branch) ;;
    esac
}

# Prints the SSH port and the provisioning command of each VM, with its MAC addresses.
macs() {
    local index=0 entry name networks macs nic
    for entry in "${VMS[@]}"; do
        read -r name _ _ networks <<< "$entry"
        index=$((index + 1))
        macs=
        nic=0
        for _ in $networks; do
            nic=$((nic + 1))
            macs+=" $(mac "$index" "$nic")"
        done
        printf '[ssh -p %s USER@127.0.0.1] ' $((2200 + index))
        case "$name" in
            gw-vpn) echo "gw-vpn:      sudo bash provision/gw-vpn.sh BUNDLE CA_KEY.pub$macs" ;;
            k8s-node) echo "k8s-node:    sudo bash provision/k8s-node.sh SYSADMIN_KEY.pub$macs" ;;
            ca) echo "ca:          sudo bash provision/ca.sh CA_KEY$macs" ;;
            cli-adm) echo "cli-adm:     sudo bash provision/cli-adm.sh admin-01.ovpn$macs" ;;
            gw-sucursal) echo "gw-sucursal: sudo bash provision/gw-sucursal.sh gw-sucursal.ovpn$macs" ;;
            host-suc) echo "host-suc:    sudo bash provision/host-suc.sh$macs" ;;
        esac
    done
}

# nat_on VM INDEX: NIC 1 is NAT, the adapter Ubuntu got DHCP on at install, for apt and images
# during provisioning only. Host port 22NN goes to SSH of VM NN, to copy the PKI files.
nat_on() {
    vbox modifyvm "$1" --nic1 nat
    vbox modifyvm "$1" --natpf1 delete ssh > /dev/null 2>&1 || true
    vbox modifyvm "$1" --natpf1 "ssh,tcp,127.0.0.1,$((2200 + $2)),,22"
}

# nat on|off: for every VM. The VMs must be off.
nat() {
    local index=0 entry name
    for entry in "${VMS[@]}"; do
        read -r name _ <<< "$entry"
        index=$((index + 1))
        exists "$name" || continue
        if [[ $1 == on ]]; then
            nat_on "$name" "$index"
        else
            vbox modifyvm "$name" --nic1 none
        fi
    done
}

# demo take|restore: the demo snapshot of each VM, taken once the lab is ready. CU4 revokes
# dev-01 for real: restore before each run of the demo. Restoring needs the VMs off.
demo() {
    local entry name
    for entry in "${VMS[@]}"; do
        read -r name _ <<< "$entry"
        exists "$name" || continue
        if [[ $1 == take ]]; then
            # Two snapshots with the same name would make restore ambiguous.
            if has_snapshot "$name" "$DEMO"; then
                vbox snapshot "$name" delete "$DEMO"
            fi
            vbox snapshot "$name" take "$DEMO"
        else
            has_snapshot "$name" "$DEMO" || fail "$name has no $DEMO snapshot: run virtualbox.sh snapshot"
            vbox snapshot "$name" restore "$DEMO"
        fi
    done
}

case "$ACTION" in
    networks)
        echo "Internet: $(hostonly "$WAN_HOST_IP")"
        echo "Management: $(hostonly "$MGMT_HOST_IP")"
        ;;
    base)
        ISO=${2:?Missing Ubuntu Server ISO}
        exists "$BASE" && fail "$BASE already exists"
        FOLDER=$(vbox list systemproperties | sed -n 's/^Default machine folder: *//p')
        vbox createvm --name "$BASE" --ostype Ubuntu_64 --register
        vbox modifyvm "$BASE" --memory 2048 --cpus 2 --nic1 nat --audio-enabled off
        # Dynamic disk: the clones only store their changes, k8s-node needs the most.
        vbox createmedium disk --filename "$FOLDER/$BASE/$BASE.vdi" --size 30000
        vbox storagectl "$BASE" --name SATA --add sata
        vbox storageattach "$BASE" --storagectl SATA --port 0 --type hdd --medium "$FOLDER/$BASE/$BASE.vdi"
        vbox storageattach "$BASE" --storagectl SATA --port 1 --type dvddrive --medium "$ISO"
        echo "Install Ubuntu Server with OpenSSH in $BASE, shut it down, then run: virtualbox.sh clones"
        ;;
    clones)
        exists "$BASE" || fail "Run virtualbox.sh base ISO first"
        WAN_IF=$(hostonly_name "$WAN_HOST_IP")
        MGMT_IF=$(hostonly_name "$MGMT_HOST_IP")
        [[ -n $WAN_IF && -n $MGMT_IF ]] || fail "Run virtualbox.sh networks first"
        if ! has_snapshot "$BASE" "$SNAPSHOT"; then
            vbox storageattach "$BASE" --storagectl SATA --port 1 --type dvddrive --medium emptydrive
            vbox snapshot "$BASE" take "$SNAPSHOT"
        fi
        INDEX=0
        for ENTRY in "${VMS[@]}"; do
            read -r NAME MEMORY CPUS NETWORKS <<< "$ENTRY"
            INDEX=$((INDEX + 1))
            if exists "$NAME"; then
                echo "$NAME already exists"
                continue
            fi
            vbox clonevm "$BASE" --snapshot "$SNAPSHOT" --options link --name "$NAME" --register
            OPTIONS=(--memory "$MEMORY" --cpus "$CPUS")
            NIC=0
            for NETWORK in $NETWORKS; do
                NIC=$((NIC + 1))
                # NIC 1 is NAT: ethN-1 is on adapter N+1, found by its MAC address.
                attach $((NIC + 1)) "$NETWORK"
                OPTIONS+=(--macaddress$((NIC + 1)) "$(mac "$INDEX" "$NIC" | tr -d :)")
            done
            vbox modifyvm "$NAME" "${OPTIONS[@]}"
            nat_on "$NAME" "$INDEX"
        done
        macs
        ;;
    macs) macs ;;
    offline) nat off ;;
    online) nat on ;;
    snapshot) demo take ;;
    restore) demo restore ;;
    *) fail "Unknown action: $ACTION" ;;
esac
