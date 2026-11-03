#!/usr/bin/env bash
# ==============================================================================
# setup-lab.sh — Orquestador Automatizado del Laboratorio VirtualBox (Redes-TPE)
# ==============================================================================
# Prepara, aprovisiona, verifica y restaura el entorno completo de 6 VMs:
#   - gw-vpn      (203.0.113.10 WAN | 10.10.0.1 LAN | 192.168.100.1 MGMT | 10.8.0.1 VPN)
#   - k8s-node    (10.10.10.5 LAN   | Kind Cluster + Ingress + 5 microservicios)
#   - ca          (192.168.100.20 MGMT | EasyRSA 3 PKI fuera de banda)
#   - cli-adm     (203.0.113.51 WAN | 10.8.0.20 VPN sysadmin)
#   - gw-sucursal (203.0.113.20 WAN | 172.16.20.1 Sucursal | 10.8.0.30 VPN site-to-site)
#   - host-suc    (172.16.20.10 Sucursal)
#
# Uso:
#   bash infra/remote-access/scripts/setup-lab.sh [comando]
#
# Comandos disponibles:
#   full        Ejecuta los Pasos 3 a 8 desde cero a partir de 'the-store-base'
#   status      Muestra el estado detallado de redes, VMs, túneles VPN y pods K8s
#   verify      Ejecuta la batería de pruebas punta a punta (CA, Sysadmin, Sucursal, Dev)
#   reset-demo  Apaga las 6 VMs, restaura el snapshot 'demo', las inicia y verifica todo
#   start       Inicia las 6 VMs en segundo plano (headless) y espera a que estén listas
#   stop        Apaga las 6 VMs limpiamente
# ==============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REMOTE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$REMOTE_DIR/../.." && pwd)

# Configuración por defecto (personalizable por variables de entorno)
GUEST_USER=${GUEST_USER:-home}
GUEST_PASS=${GUEST_PASS:-bishbashbosh}
CA_PASS=${CA_PASS:-$GUEST_PASS}
PROFILES_DIR="$REMOTE_DIR/profiles"
BUNDLES_DIR="$REMOTE_DIR/bundles"
HOST_KEY="$PROFILES_DIR/host_admin_ed25519"
CA_KEY="$PROFILES_DIR/ca_ed25519"
SYSADMIN_KEY="$PROFILES_DIR/sysadmin_ed25519"

# Direcciones MAC fijas asignadas por virtualbox.sh en las interfaces internas (NIC 2+)
MAC_GW_VPN_WAN="08:00:27:00:01:01"
MAC_GW_VPN_LAN="08:00:27:00:01:02"
MAC_GW_VPN_MGMT="08:00:27:00:01:03"
MAC_K8S_NODE_LAN="08:00:27:00:02:01"
MAC_CA_MGMT="08:00:27:00:03:01"
MAC_CLI_ADM_WAN="08:00:27:00:04:01"
MAC_GW_SUC_WAN="08:00:27:00:05:01"
MAC_GW_SUC_BRANCH="08:00:27:00:05:02"
MAC_HOST_SUC_BRANCH="08:00:27:00:06:01"

ALL_VMS=(gw-vpn k8s-node ca cli-adm gw-sucursal host-suc)

# Detectar VBoxManage en Linux/macOS/Windows (Git Bash)
if command -v VBoxManage >/dev/null 2>&1; then
    VBOX="VBoxManage"
elif [[ -x "/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" ]]; then
    VBOX="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
    export PATH="/c/Program Files/Oracle/VirtualBox:$PATH"
else
    echo "ERROR: No se encontró VBoxManage. Instalá VirtualBox 7 primero." >&2
    exit 1
fi

# Colores y funciones de formato informativo
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_BLUE='\033[1;34m'
    C_CYAN='\033[1;36m'
    C_GREEN='\033[1;32m'
    C_YELLOW='\033[1;33m'
    C_RED='\033[1;31m'
else
    C_RESET='' C_BOLD='' C_BLUE='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED=''
fi

banner() {
    printf "\n${C_BLUE}==============================================================================${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}  %s${C_RESET}\n" "$*"
    printf "${C_BLUE}==============================================================================${C_RESET}\n"
}

step()  { printf "${C_CYAN}[PASO]${C_RESET} %s\n" "$*"; }
info()  { printf "  ${C_BLUE}->${C_RESET} %s\n" "$*"; }
ok()    { printf "  ${C_GREEN}[OK]${C_RESET} %s\n" "$*"; }
warn()  { printf "  ${C_YELLOW}[AVISO]${C_RESET} %s\n" "$*"; }
err()   { printf "  ${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2; exit 1; }

SSH_OPTS=(-i "$HOST_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)

ssh_nat()  { local port=$1; shift; ssh "${SSH_OPTS[@]}" -p "$port" "$GUEST_USER@127.0.0.1" "$@"; }
scp_nat()  { local port=$1; shift; scp "${SSH_OPTS[@]}" -P "$port" "$@"; }
ssh_ip()   { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" "$@"; }

# ------------------------------------------------------------------------------
# Funciones de ciclo de vida de VMs
# ------------------------------------------------------------------------------
start_all_vms() {
    step "Iniciando las 6 VMs en modo headless (segundo plano)..."
    local running vm
    running=$("$VBOX" list runningvms | tr -d '\r')
    for vm in "${ALL_VMS[@]}"; do
        if grep -q "\"$vm\"" <<<"$running"; then
            info "VM '$vm' ya está encendida."
        else
            info "Encendiendo VM '$vm'..."
            "$VBOX" startvm "$vm" --type headless >/dev/null
            sleep 2
        fi
    done
    ok "Las 6 VMs están en ejecución."
}

stop_all_vms() {
    step "Apagando las 6 VMs..."
    local vm i running
    for vm in host-suc gw-sucursal cli-adm ca k8s-node gw-vpn; do
        "$VBOX" controlvm "$vm" acpipowerbutton 2>/dev/null || true
    done
    for i in {1..15}; do
        running=$("$VBOX" list runningvms | tr -d '\r')
        [[ -z "$running" ]] && { ok "Las 6 VMs se apagaron limpiamente."; return 0; }
        sleep 2
    done
    warn "Algunas VMs siguen encendidas; forzando poweroff..."
    for vm in host-suc gw-sucursal cli-adm ca k8s-node gw-vpn; do
        "$VBOX" controlvm "$vm" poweroff 2>/dev/null || true
    done
    sleep 3
    ok "Las 6 VMs están apagadas."
}

wait_for_offline_hosts() {
    step "Esperando conectividad SSH en las redes de Gestión (192.168.100.0/24) y WAN (203.0.113.0/24)..."
    local entry host name i
    for entry in "192.168.100.1:gw-vpn" "192.168.100.20:ca" "203.0.113.51:cli-adm"; do
        host=${entry%%:*}
        name=${entry##*:}
        info "Esperando a $name ($host)..."
        for i in {1..45}; do
            if ssh_ip "$host" "hostname" >/dev/null 2>&1; then
                ok "$name ($host) responde por SSH."
                break
            fi
            [[ $i -eq 45 ]] && err "Tiempo de espera agotado esperando a $name ($host)."
            sleep 2
        done
    done

    step "Esperando que los clientes VPN (admin-01 y gw-sucursal) establezcan túnel con gw-vpn..."
    local status
    for i in {1..30}; do
        status=$(ssh_ip 192.168.100.1 "echo $GUEST_PASS | sudo -S cat /run/openvpn-server/the-store-status.log 2>/dev/null || true")
        if echo "$status" | grep -q "CLIENT_LIST,admin-01" && echo "$status" | grep -q "CLIENT_LIST,gw-sucursal"; then
            ok "Túneles activos en gw-vpn:"
            echo "$status" | grep "^CLIENT_LIST" | sed 's/^/      /'
            break
        fi
        [[ $i -eq 30 ]] && err "Los túneles VPN no se conectaron a tiempo."
        sleep 2
    done

    step "Esperando que el cluster Kubernetes en k8s-node (10.10.10.5) tenga todos los microservicios listos..."
    for i in {1..60}; do
        if ssh_ip 203.0.113.51 "curl -fsS --max-time 5 http://ui.the-store.internal/actuator/health/readiness >/dev/null 2>&1"; then
            ok "Ingress y microservicios de 'the-store' respondiendo en http://*.the-store.internal"
            break
        fi
        [[ $i -eq 60 ]] && err "El Ingress en 10.10.10.5:80 no respondió a tiempo."
        sleep 3
    done
}

# ------------------------------------------------------------------------------
# Comando: status
# ------------------------------------------------------------------------------
cmd_status() {
    banner "ESTADO DEL LABORATORIO VIRTUALBOX (REDES-TPE)"

    step "1. Redes Host-Only en el Host:"
    "$VBOX" list hostonlyifs | grep -E "^(Name|IPAddress|NetworkMask|Status):" | sed 's/^/     /'

    step "2. Máquinas Virtuales en ejecución:"
    local running
    running=$("$VBOX" list runningvms | tr -d '\r')
    if [[ -z "$running" ]]; then
        warn "No hay ninguna VM encendida actualmente."
        return 0
    fi
    echo "$running" | sed 's/^/     /'

    step "3. Estado de Clientes Conectados en gw-vpn (192.168.100.1):"
    if ssh_ip 192.168.100.1 "true" 2>/dev/null; then
        ssh_ip 192.168.100.1 "echo $GUEST_PASS | sudo -S cat /run/openvpn-server/the-store-status.log 2>/dev/null" | \
            grep -E "^(CLIENT_LIST|ROUTING_TABLE)" | sed 's/^/     /' || true
    else
        warn "gw-vpn (192.168.100.1) no responde por SSH en este momento."
    fi

    step "4. Estado de Pods en k8s-node (consultado desde cli-adm 203.0.113.51 -> 10.10.10.5:6443):"
    if ssh_ip 203.0.113.51 "true" 2>/dev/null; then
        ssh_ip 203.0.113.51 "kubectl get pods -n the-store -o wide" | sed 's/^/     /' || true
    else
        warn "cli-adm (203.0.113.51) no responde por SSH en este momento."
    fi
}

# ------------------------------------------------------------------------------
# Comando: verify (Pruebas integrales punta a punta en modo offline)
# ------------------------------------------------------------------------------
cmd_verify() {
    banner "VERIFICACIÓN INTEGRAL PUNTA A PUNTA (MODO OFFLINE)"
    wait_for_offline_hosts

    step "1. Probando publicación de CRL desde 'ca' (192.168.100.20) hacia 'gw-vpn' (192.168.100.1)..."
    ssh_ip 192.168.100.20 "echo $GUEST_PASS | sudo -S bash -c '
        export EASYRSA_PASSIN=pass:$CA_PASS
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store gen-crl
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store publish-crl
    '" | sed 's/^/     /'
    ok "CA generó y publicó la CRL en gw-vpn por la red de gestión."

    step "2. Probando perfil Sysadmin desde 'cli-adm' (203.0.113.51, túnel 10.8.0.20)..."
    ssh_ip 203.0.113.51 '
        set -euo pipefail
        for svc in ui carts orders; do
            curl -fsS --max-time 10 "http://${svc}.the-store.internal/actuator/health/readiness" >/dev/null
            echo "     [OK] HTTP GET http://${svc}.the-store.internal/actuator/health/readiness"
        done
        for svc in catalog checkout; do
            curl -fsS --max-time 10 "http://${svc}.the-store.internal/health" >/dev/null
            echo "     [OK] HTTP GET http://${svc}.the-store.internal/health"
        done
        kubectl get pods -n the-store >/dev/null
        echo "     [OK] kubectl get pods -n the-store permitido"
        if kubectl get secrets -n the-store >/dev/null 2>&1; then
            echo "     [FALLO] sysadmin pudo leer secrets"; exit 1
        else
            echo "     [OK] kubectl get secrets -n the-store denegado por RBAC"
        fi
        node_host=$(ssh -o StrictHostKeyChecking=no root@10.10.10.5 hostname)
        echo "     [OK] SSH root@10.10.10.5 -> hostname: $node_host"
    '
    ok "Todas las verificaciones de Sysadmin (cli-adm) pasaron."

    step "3. Ejecutando suite 'tests/kubernetes.sh' directamente en 'k8s-node' (10.10.10.5)..."
    ssh_ip 203.0.113.51 "ssh -o StrictHostKeyChecking=no root@10.10.10.5 'export PATH=/usr/local/bin:\$PATH; KUBECONFIG=/home/$GUEST_USER/.kube/config REQUIRE_CLUSTER=1 bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/tests/kubernetes.sh'" | sed 's/^/     /'
    ok "Suite kubernetes.sh completada (13/13 controles OK)."

    step "4. Probando LAN de Sucursal desde 'host-suc' (172.16.20.10 -> gw-sucursal 172.16.20.1 -> túnel 10.8.0.30)..."
    MSYS2_ARG_CONV_EXCL="*" "$VBOX" guestcontrol host-suc run --exe /bin/bash --username "$GUEST_USER" --password "$GUEST_PASS" -- -c '
        set -euo pipefail
        resolved=$(dig +short @172.16.20.1 ui.the-store.internal)
        [[ "$resolved" == "10.10.10.5" ]] && echo "     [OK] DNS @172.16.20.1 ui.the-store.internal -> $resolved"
        for svc in ui carts orders; do
            curl -fsS --max-time 10 "http://${svc}.the-store.internal/actuator/health/readiness" >/dev/null
            echo "     [OK] host-suc HTTP -> http://${svc}.the-store.internal"
        done
        for svc in catalog checkout; do
            curl -fsS --max-time 10 "http://${svc}.the-store.internal/health" >/dev/null
            echo "     [OK] host-suc HTTP -> http://${svc}.the-store.internal"
        done
        if timeout 3 bash -c "true </dev/tcp/10.10.10.5/22" 2>/dev/null; then
            echo "     [FALLO] host-suc alcanzó 10.10.10.5:22"; exit 1
        else
            echo "     [OK] Firewall bloqueó acceso de sucursal a 10.10.10.5:22 (SSH)"
        fi
        if timeout 3 bash -c "true </dev/tcp/10.10.10.5/6443" 2>/dev/null; then
            echo "     [FALLO] host-suc alcanzó 10.10.10.5:6443"; exit 1
        else
            echo "     [OK] Firewall bloqueó acceso de sucursal a 10.10.10.5:6443 (K8s API)"
        fi
    '
    ok "Todas las verificaciones de la Sucursal (host-suc + gw-sucursal) pasaron."

    banner "¡VERIFICACIÓN COMPLETA EXITOSA! TODOS LOS SISTEMAS OPERATIVOS"
}

# ------------------------------------------------------------------------------
# Comando: reset-demo (Restaurar snapshot 'demo' y levantar laboratorio)
# ------------------------------------------------------------------------------
cmd_reset_demo() {
    banner "RESTAURACIÓN DEL SNAPSHOT 'demo' EN LAS 6 VMs"
    stop_all_vms
    step "Ejecutando 'virtualbox.sh restore' para volver las 6 VMs al snapshot 'demo'..."
    bash "$SCRIPT_DIR/virtualbox.sh" restore
    ok "Snapshot 'demo' restaurado en las 6 VMs."
    start_all_vms
    wait_for_offline_hosts
    banner "ENTORNO RESTAURADO Y LISTO PARA DEMO"
}

# ------------------------------------------------------------------------------
# Comando: full (Aprovisionamiento completo Pasos 3 a 8 desde the-store-base)
# ------------------------------------------------------------------------------
cmd_full() {
    banner "DESPLIEGUE COMPLETO DEL LABORATORIO DESDE 'the-store-base' (PASOS 3 A 8)"

    if "$VBOX" snapshot gw-vpn list 2>/dev/null | grep -q "Name: demo (" && [[ "${RECREATE:-0}" != "1" ]]; then
        info "Las 6 VMs ya existen, ya fueron aprovisionadas y están en modo OFFLINE (sin NAT en puertos 2201-2206)."
        info "Restaurando el snapshot 'demo' y ejecutando la verificación completa..."
        info "(Si querés borrar las 6 VMs y reconstruir desde cero con NAT, ejecutá con RECREATE=1)."
        cmd_reset_demo
        cmd_verify
        return 0
    fi

    if [[ "${RECREATE:-0}" == "1" ]]; then
        stop_all_vms
        step "Eliminando clones existentes para reconstruir desde 'the-store-base'..."
        for vm in "${ALL_VMS[@]}"; do
            "$VBOX" unregistervm "$vm" --delete 2>/dev/null || true
        done
    fi

    step "Paso 3: Creando los 6 clones vinculados desde 'the-store-base'..."
    bash "$SCRIPT_DIR/virtualbox.sh" clones
    ok "Clones vinculados creados con NAT temporal en NIC 1 (puertos 2201-2206)."

    start_all_vms

    step "Esperando acceso SSH inicial por NAT (127.0.0.1:2201..2206) e instalando claves SSH..."
    mkdir -p "$PROFILES_DIR" "$BUNDLES_DIR"
    [[ -f "$HOST_KEY" ]]     || ssh-keygen -q -t ed25519 -N '' -C "host-admin" -f "$HOST_KEY"
    [[ -f "$CA_KEY" ]]       || ssh-keygen -q -t ed25519 -N '' -C "ca@the-store" -f "$CA_KEY"
    [[ -f "$SYSADMIN_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C "sysadmin@the-store" -f "$SYSADMIN_KEY"

    local idx=0 vm port pubkey
    pubkey=$(cat "$HOST_KEY.pub")
    for vm in "${ALL_VMS[@]}"; do
        idx=$((idx + 1))
        port=$((2200 + idx))
        info "Configurando clave SSH, sudo sin contraseña para aprovisionamiento y hostname en '$vm' (puerto $port)..."
        ssh_nat "$port" "echo $GUEST_PASS | sudo -S bash -c '
            hostnamectl set-hostname $vm
            sed -i \"s/the-store-base/$vm/g\" /etc/hosts
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq virtualbox-guest-utils curl dnsutils
        '"
        info "Sincronizando repositorio a $vm:/home/$GUEST_USER/Redes-TPE..."
        tar -C "$REPO_ROOT" --exclude='.git' --exclude='node_modules' --exclude='infra/remote-access/profiles' \
            --exclude='infra/remote-access/bundles' -czf - . | \
            ssh_nat "$port" "mkdir -p /home/$GUEST_USER/Redes-TPE && tar -C /home/$GUEST_USER/Redes-TPE -xzf -"
    done
    ok "Las 6 VMs tienen el repositorio sincronizado y acceso SSH por clave."

    banner "PASOS 4 Y 5: GENERACIÓN DE PKI EN 'ca' Y DISTRIBUCIÓN DE BUNDLE Y PERFILES"
    scp_nat 2203 "$CA_KEY" "$CA_KEY.pub" "$GUEST_USER@127.0.0.1:/tmp/"
    ssh_nat 2203 "echo $GUEST_PASS | sudo -S bash -c '
        mv /tmp/ca_ed25519 /root/ca_key && mv /tmp/ca_ed25519.pub /root/ca_key.pub
        chmod 600 /root/ca_key && chmod 644 /root/ca_key.pub
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/provision/ca.sh /root/ca_key $MAC_CA_MGMT
        rm -rf /root/ca-store /tmp/gw-vpn-bundle /tmp/*.ovpn
        export EASYRSA_PASSOUT=pass:$CA_PASS EASYRSA_PASSIN=pass:$CA_PASS
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store init
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store issue-server
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store issue-client dev-01 dev 10
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store issue-client admin-01 sysadmin 20
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store issue-client gw-sucursal sucursal 30
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store export-server /tmp/gw-vpn-bundle
        for c in dev-01 admin-01 gw-sucursal; do
            bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store export-client \$c /tmp/\$c.ovpn
        done
        chown -R $GUEST_USER:$GUEST_USER /tmp/gw-vpn-bundle /tmp/*.ovpn
    '"
    rm -rf "$BUNDLES_DIR/gw-vpn-bundle"
    scp_nat 2203 -r "$GUEST_USER@127.0.0.1:/tmp/gw-vpn-bundle" "$BUNDLES_DIR/gw-vpn-bundle"
    scp_nat 2203 "$GUEST_USER@127.0.0.1:/tmp/dev-01.ovpn" "$PROFILES_DIR/dev-01.ovpn"
    scp_nat 2203 "$GUEST_USER@127.0.0.1:/tmp/admin-01.ovpn" "$PROFILES_DIR/admin-01.ovpn"
    scp_nat 2203 "$GUEST_USER@127.0.0.1:/tmp/gw-sucursal.ovpn" "$PROFILES_DIR/gw-sucursal.ovpn"
    ok "PKI generada en 'ca' y perfiles/bundle descargados en $PROFILES_DIR y $BUNDLES_DIR."

    banner "PASO 6: PROVISIONING DE TODAS LAS VMs Y CLUSTER KUBERNETES EN 'k8s-node'"

    step "Aprovisionando 'gw-vpn' (puerto 2201)..."
    scp_nat 2201 -r "$BUNDLES_DIR/gw-vpn-bundle" "$CA_KEY.pub" "$GUEST_USER@127.0.0.1:/tmp/"
    ssh_nat 2201 "echo $GUEST_PASS | sudo -S bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/provision/gw-vpn.sh /tmp/gw-vpn-bundle /tmp/ca_ed25519.pub $MAC_GW_VPN_WAN $MAC_GW_VPN_LAN $MAC_GW_VPN_MGMT"
    ok "'gw-vpn' aprovisionado."

    step "Aprovisionando 'cli-adm' (puerto 2204)..."
    scp_nat 2204 "$PROFILES_DIR/admin-01.ovpn" "$SYSADMIN_KEY" "$SYSADMIN_KEY.pub" "$GUEST_USER@127.0.0.1:/tmp/"
    ssh_nat 2204 "echo $GUEST_PASS | sudo -S bash -c '
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/provision/cli-adm.sh /tmp/admin-01.ovpn $MAC_CLI_ADM_WAN
        install -m 600 -o $GUEST_USER -g $GUEST_USER /tmp/sysadmin_ed25519 /home/$GUEST_USER/.ssh/id_ed25519
        install -m 644 -o $GUEST_USER -g $GUEST_USER /tmp/sysadmin_ed25519.pub /home/$GUEST_USER/.ssh/id_ed25519.pub
        mkdir -p /etc/systemd/system/openvpn-client@the-store.service.d
        cat > /etc/systemd/system/openvpn-client@the-store.service.d/restart.conf <<\"EOF\"
[Unit]
After=network-online.target systemd-networkd-wait-online.service
Wants=network-online.target systemd-networkd-wait-online.service
[Service]
Restart=always
RestartSec=3
ExecStartPost=/bin/bash -c \"for i in {1..20}; do if ip -4 addr show dev tun0 2>/dev/null | grep -q 10.8.0.; then resolvectl dns tun0 10.8.0.1 && resolvectl domain tun0 ~the-store.internal && exit 0; fi; sleep 1; done; exit 0\"
EOF
        systemctl daemon-reload
    '"
    ok "'cli-adm' aprovisionado."

    step "Aprovisionando 'gw-sucursal' (puerto 2205) y 'host-suc' (puerto 2206)..."
    scp_nat 2205 "$PROFILES_DIR/gw-sucursal.ovpn" "$GUEST_USER@127.0.0.1:/tmp/"
    ssh_nat 2205 "echo $GUEST_PASS | sudo -S bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/provision/gw-sucursal.sh /tmp/gw-sucursal.ovpn $MAC_GW_SUC_WAN $MAC_GW_SUC_BRANCH"
    ssh_nat 2206 "echo $GUEST_PASS | sudo -S bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/provision/host-suc.sh $MAC_HOST_SUC_BRANCH"
    ok "'gw-sucursal' y 'host-suc' aprovisionados."

    step "Aprovisionando 'k8s-node' (puerto 2202), construyendo imágenes y desplegando el cluster Kind..."
    scp_nat 2202 "$SYSADMIN_KEY.pub" "$GUEST_USER@127.0.0.1:/tmp/sysadmin_ed25519.pub"
    ssh_nat 2202 "echo $GUEST_PASS | sudo -S bash -c '
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/provision/k8s-node.sh /tmp/sysadmin_ed25519.pub $MAC_K8S_NODE_LAN
        usermod -aG docker $GUEST_USER
        netplan apply
        [[ -x /usr/local/bin/kind ]] || { curl -fsSL -o /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64 && chmod +x /usr/local/bin/kind; }
        [[ -x /usr/local/bin/kubectl ]] || { KVER=\$(curl -fsSL https://dl.k8s.io/release/stable.txt) && curl -fsSL -o /usr/local/bin/kubectl \"https://dl.k8s.io/release/\$KVER/bin/linux/amd64/kubectl\" && chmod +x /usr/local/bin/kubectl; }
        su - $GUEST_USER -c \"cd /home/$GUEST_USER/Redes-TPE && ./local.sh build && ./local.sh create-cluster --remote-access --skip-tests\"
        su - $GUEST_USER -c \"cd /home/$GUEST_USER/Redes-TPE && REQUIRE_CLUSTER=1 bash infra/remote-access/tests/kubernetes.sh\"
        su - $GUEST_USER -c \"cd /home/$GUEST_USER/Redes-TPE && bash infra/remote-access/scripts/sysadmin-kubeconfig.sh /tmp/sysadmin.kubeconfig\"
    '"
    scp_nat 2202 "$GUEST_USER@127.0.0.1:/usr/local/bin/kubectl" "$PROFILES_DIR/kubectl"
    scp_nat 2202 "$GUEST_USER@127.0.0.1:/tmp/sysadmin.kubeconfig" "$PROFILES_DIR/sysadmin.kubeconfig"
    scp_nat 2204 "$PROFILES_DIR/kubectl" "$PROFILES_DIR/sysadmin.kubeconfig" "$GUEST_USER@127.0.0.1:/tmp/"
    ssh_nat 2204 "echo $GUEST_PASS | sudo -S bash -c '
        install -m 755 /tmp/kubectl /usr/local/bin/kubectl
        install -d -m 700 -o $GUEST_USER -g $GUEST_USER /home/$GUEST_USER/.kube
        install -m 600 -o $GUEST_USER -g $GUEST_USER /tmp/sysadmin.kubeconfig /home/$GUEST_USER/.kube/config
        rm -f /tmp/kubectl /tmp/sysadmin.kubeconfig
    '"
    ok "'k8s-node' y 'cli-adm' listos con cluster Kind y sysadmin.kubeconfig."

    banner "PASOS 7 Y 8: CORTE DE INTERNET (OFFLINE), VERIFICACIÓN Y SNAPSHOT 'demo'"
    stop_all_vms
    step "Cortando el acceso a internet en las 6 VMs con 'virtualbox.sh offline'..."
    bash "$SCRIPT_DIR/virtualbox.sh" offline
    start_all_vms
    cmd_verify
    stop_all_vms
    step "Tomando snapshot 'demo' en las 6 VMs con 'virtualbox.sh snapshot'..."
    bash "$SCRIPT_DIR/virtualbox.sh" snapshot
    ok "Snapshot 'demo' creado."
    start_all_vms
    wait_for_offline_hosts
    banner "¡LABORATORIO COMPLETAMENTE DESPLEGADO, VERIFICADO Y SNAPSHOTEADO!"
}

# ------------------------------------------------------------------------------
# Punto de entrada principal (con pausa interactiva y log en archivo)
# ------------------------------------------------------------------------------
mkdir -p "$PROFILES_DIR"
LOG_FILE="$PROFILES_DIR/setup-lab.log"
NO_PAUSE=${NO_PAUSE:-0}
[[ "${2:-}" == "--no-pause" ]] && NO_PAUSE=1

on_exit() {
    local code=$?
    printf "\n${C_CYAN}[LOG]${C_RESET} Salida completa guardada en: %s\n" "$LOG_FILE"
    if [[ -t 0 && "$NO_PAUSE" == "0" ]]; then
        printf "\n${C_BOLD}${C_YELLOW}Ejecución finalizada (código %d). Presioná ENTER para cerrar...${C_RESET}" "$code"
        read -r _ || true
    fi
}
trap on_exit EXIT

ACTION=${1:-}
if [[ -z "$ACTION" && -t 0 ]]; then
    banner "MENÚ INTERACTIVO — LABORATORIO VIRTUALBOX (REDES-TPE)"
    echo "  1) status      - Ver estado de redes, VMs, túneles VPN y pods K8s"
    echo "  2) verify      - Ejecutar pruebas integrales punta a punta (CA, Sysadmin, K8s, Sucursal)"
    echo "  3) reset-demo  - Apagar VMs, restaurar snapshot 'demo', iniciar y verificar"
    echo "  4) start       - Iniciar las 6 VMs en segundo plano"
    echo "  5) stop        - Apagar las 6 VMs limpiamente"
    echo "  6) full        - Desplegar Pasos 3 a 8 desde cero a partir de 'the-store-base'"
    echo ""
    printf "Elegí una opción [1-6 o nombre, Enter=1 (status)]: "
    read -r choice || true
    case "${choice:-1}" in
        1|status)     ACTION="status" ;;
        2|verify)     ACTION="verify" ;;
        3|reset-demo) ACTION="reset-demo" ;;
        4|start)      ACTION="start" ;;
        5|stop)       ACTION="stop" ;;
        6|full)       ACTION="full" ;;
        *)            ACTION="$choice" ;;
    esac
elif [[ -z "$ACTION" ]]; then
    ACTION="status"
fi

{
    case "$ACTION" in
        full|provision)     cmd_full ;;
        status)             cmd_status ;;
        verify|test)        cmd_verify ;;
        reset-demo|restore) cmd_reset_demo ;;
        start)              start_all_vms; wait_for_offline_hosts ;;
        stop)               stop_all_vms ;;
        *)
            echo "Uso: $0 {status|verify|reset-demo|start|stop|full}" >&2
            exit 1
            ;;
    esac
} 2>&1 | tee "$LOG_FILE"


