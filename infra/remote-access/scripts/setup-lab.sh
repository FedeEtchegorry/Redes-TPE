#!/usr/bin/env bash
# Laboratorio VirtualBox de 6 VMs. Uso: setup-lab.sh [comando]
#   full        Pasos 1 a 8 desde cero (crea redes y 'the-store-base' con Ubuntu si faltan)
#   status      Estado de redes, VMs, túneles VPN y pods K8s
#   verify      Pruebas punta a punta (CA, Sysadmin, Sucursal, Dev)
#   reset-demo  Apaga las 6 VMs, restaura el snapshot 'demo', las inicia y verifica
#   start       Inicia las 6 VMs (headless) y espera a que estén listas
#   stop        Apaga las 6 VMs
#   eval        Simula la corrección de la defensa (CU1..CU6); restaura el snapshot 'demo' al empezar y al terminar

set -euo pipefail

LOG_NAME=setup-lab
source "$(dirname "${BASH_SOURCE[0]}")/lab-common.sh"
REPO_ROOT=$(cd "$REMOTE_DIR/../.." && pwd)
BUNDLES_DIR="$REMOTE_DIR/bundles"
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

step()  { log_out "${C_CYAN}[PASO]${C_RESET} $*\n"; }
info()  { log_out "  ${C_BLUE}->${C_RESET} $*\n"; }
ok()    { log_out "  ${C_GREEN}[OK]${C_RESET} $*\n"; }
warn()  { log_out "  ${C_YELLOW}[AVISO]${C_RESET} $*\n"; }
err()   { log_out "  ${C_RED}[ERROR]${C_RESET} $*\n" >&2; exit 1; }

ssh_nat()  { local port=$1; shift; ssh "${SSH_OPTS[@]}" -p "$port" "$GUEST_USER@127.0.0.1" "$@"; }
scp_nat()  { local port=$1; shift; scp "${SSH_OPTS[@]}" -P "$port" "$@"; }

install_host_key() {
    local port=$1 askpass key out="" i rc=1
    key=$(cat "$HOST_KEY.pub")
    askpass=$(mktemp)
    printf '#!/bin/sh\necho "$GUEST_PASS"\n' > "$askpass"
    chmod +x "$askpass"
    for i in {1..60}; do
        out=$(GUEST_PASS=$GUEST_PASS SSH_ASKPASS=$askpass SSH_ASKPASS_REQUIRE=force \
            ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR \
                -p "$port" "$GUEST_USER@127.0.0.1" \
                "umask 077; mkdir -p ~/.ssh; grep -qxF '$key' ~/.ssh/authorized_keys 2>/dev/null || echo '$key' >> ~/.ssh/authorized_keys" \
                </dev/null 2>&1) && { rc=0; break; }
        [[ $out == *"Permission denied"* ]] && break
        sleep 3
    done
    rm -f "$askpass"
    [[ $rc == 0 ]] || err "La VM del puerto $port no aceptó la contraseña de '$GUEST_USER' o no respondió por SSH: $out"
}

start_all_vms() {
    step "Iniciando las 6 VMs en modo headless (segundo plano)..."
    local running vm
    running=$("$VBOX" list runningvms </dev/null | tr -d '\r')
    for vm in "${ALL_VMS[@]}"; do
        if grep -q "\"$vm\"" <<<"$running"; then
            info "VM '$vm' ya está encendida."
        else
            info "Encendiendo VM '$vm'..."
            "$VBOX" startvm "$vm" --type headless </dev/null >/dev/null 2>&1
            sleep 2
        fi
    done
    ok "Las 6 VMs están en ejecución."
}

stop_all_vms() {
    step "Apagando las 6 VMs..."
    local vm running
    running=$("$VBOX" list runningvms </dev/null | tr -d '\r')
    if [[ -z "$running" ]]; then
        ok "Las 6 VMs ya están apagadas."
        return 0
    fi
    # Apagado ordenado primero: un poweroff en seco pierde lo último escrito a disco.
    for vm in "${ALL_VMS[@]}"; do
        grep -q "\"$vm\"" <<<"$running" && "$VBOX" controlvm "$vm" acpipowerbutton </dev/null >/dev/null 2>&1 || true
    done
    for _ in {1..30}; do
        [[ -z "$("$VBOX" list runningvms </dev/null | tr -d '\r')" ]] && break
        sleep 2
    done
    running=$("$VBOX" list runningvms </dev/null | tr -d '\r')
    for vm in host-suc gw-sucursal cli-adm ca k8s-node gw-vpn; do
        if grep -q "\"$vm\"" <<<"$running"; then
            info "Apagando VM '$vm'..."
            timeout 3 "$VBOX" guestcontrol "$vm" closesession --all </dev/null >/dev/null 2>&1 || true
            if ! timeout 8 "$VBOX" controlvm "$vm" poweroff </dev/null >/dev/null 2>&1; then
                warn "VM '$vm' no respondió a poweroff en 8s; cerrando proceso VBoxHeadless..."
                powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='VBoxHeadless.exe' AND CommandLine LIKE '%--comment $vm --startvm%'\" | Invoke-CimMethod -MethodName Terminate" </dev/null >/dev/null 2>&1 || true
            fi
            sleep 1
        fi
    done
    sleep 2
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
                ssh_ip "$host" "echo $GUEST_PASS | sudo -S date -u -s '@$(date -u +%s)' >/dev/null 2>&1 || true"
                ok "$name ($host) responde por SSH (reloj UTC sincronizado)."
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
        if ssh_ip 203.0.113.51 'for s in ui carts orders; do curl -fsS --max-time 5 "http://$s.the-store.internal/actuator/health/readiness" || exit 1; done; for s in catalog checkout; do curl -fsS --max-time 5 "http://$s.the-store.internal/health" || exit 1; done' >/dev/null 2>&1; then
            ok "Los 5 microservicios de 'the-store' responden por el Ingress en http://*.the-store.internal"
            break
        fi
        [[ $i -eq 60 ]] && err "El Ingress en 10.10.10.5:80 no respondió a tiempo."
        sleep 3
    done
}

publish_crl() {
    ssh_ip 192.168.100.20 "echo $GUEST_PASS | sudo -S bash -c '
        set -e
        ssh-keygen -F 192.168.100.1 -f /root/.ssh/known_hosts >/dev/null 2>&1 || ssh-keyscan -H 192.168.100.1 >> /root/.ssh/known_hosts 2>/dev/null
        export EASYRSA_PASSIN=pass:$CA_PASS
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store gen-crl
        sleep 2
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store publish-crl
    '" | sed 's/^/     /'
}

refresh_demo_credentials() {
    step "Renovando CRL y kubeconfig de sysadmin (el snapshot 'demo' los trae viejos)..."
    publish_crl
    ssh_ip 203.0.113.51 bash -s -- "$GUEST_USER" <<'EOF'
set -euo pipefail
user=$1
new=$(mktemp)
ssh -n -o StrictHostKeyChecking=no root@10.10.10.5 "
    set -e
    f=\$(mktemp -u)
    export PATH=/usr/local/bin:\$PATH
    KUBECONFIG=/home/$user/.kube/config bash /home/$user/Redes-TPE/infra/remote-access/scripts/sysadmin-kubeconfig.sh \$f >/dev/null
    cat \$f; rm -f \$f
" > "$new"
install -m 600 "$new" "$HOME/.kube/config"
rm -f "$new"
kubectl get pods -n the-store >/dev/null
EOF
    ok "CRL publicada y kubeconfig de sysadmin renovado en cli-adm (kubectl get pods OK)."
}

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

cmd_verify() {
    banner "VERIFICACIÓN INTEGRAL PUNTA A PUNTA (MODO OFFLINE)"
    wait_for_offline_hosts

    step "1. Probando publicación de CRL desde 'ca' (192.168.100.20) hacia 'gw-vpn' (192.168.100.1)..."
    publish_crl
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
    ok "Suite kubernetes.sh completada."

    step "4. Probando LAN de Sucursal desde 'host-suc' (172.16.20.10 -> gw-sucursal 172.16.20.1 -> túnel 10.8.0.30)..."
    MSYS2_ARG_CONV_EXCL="*" "$VBOX" guestcontrol host-suc run --exe /bin/bash --username "$GUEST_USER" --password "$GUEST_PASS" -- -c '
        set -euo pipefail
        resolved=$(dig +short @172.16.20.1 ui.the-store.internal)
        [[ "$resolved" == "10.10.10.5" ]] || { echo "     [FALLO] DNS @172.16.20.1 ui.the-store.internal -> $resolved"; exit 1; }
        echo "     [OK] DNS @172.16.20.1 ui.the-store.internal -> $resolved"
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

    banner "VERIFICACIÓN COMPLETA"
}

cmd_reset_demo() {
    banner "RESTAURACIÓN DEL SNAPSHOT 'demo' EN LAS 6 VMs"
    stop_all_vms
    step "Ejecutando 'virtualbox.sh restore' para volver las 6 VMs al snapshot 'demo'..."
    bash "$SCRIPT_DIR/virtualbox.sh" restore
    ok "Snapshot 'demo' restaurado en las 6 VMs."
    start_all_vms
    wait_for_offline_hosts
    refresh_demo_credentials
    banner "ENTORNO RESTAURADO Y LISTO PARA DEMO"
}

cmd_full() {
    banner "DESPLIEGUE COMPLETO DEL LABORATORIO DESDE 'the-store-base' (PASOS 1 A 8)"

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
    else
        for vm in "${ALL_VMS[@]}"; do
            if "$VBOX" showvminfo "$vm" >/dev/null 2>&1; then
                err "La VM '$vm' ya existe pero no hay snapshot 'demo' (corrida anterior a medias). Reintentá con RECREATE=1."
            fi
        done
    fi

    step "Pasos 1 y 2: Redes host-only y VM base 'the-store-base' (se crean si faltan; el SO se instala solo)..."
    bash "$SCRIPT_DIR/virtualbox.sh" networks
    "$VBOX" showvminfo the-store-base >/dev/null 2>&1 || bash "$SCRIPT_DIR/virtualbox.sh" base

    step "Paso 3: Creando los 6 clones vinculados desde 'the-store-base'..."
    bash "$SCRIPT_DIR/virtualbox.sh" clones
    ok "Clones vinculados creados con NAT temporal en NIC 1 (puertos 2201-2206)."

    start_all_vms

    step "Esperando acceso SSH inicial por NAT (127.0.0.1:2201..2206) e instalando claves SSH..."
    mkdir -p "$PROFILES_DIR" "$BUNDLES_DIR"
    [[ -f "$HOST_KEY" ]]     || ssh-keygen -q -t ed25519 -N '' -C "host-admin" -f "$HOST_KEY"
    [[ -f "$CA_KEY" ]]       || ssh-keygen -q -t ed25519 -N '' -C "ca@the-store" -f "$CA_KEY"
    [[ -f "$SYSADMIN_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C "sysadmin@the-store" -f "$SYSADMIN_KEY"

    local idx=0 vm port
    for vm in "${ALL_VMS[@]}"; do
        idx=$((idx + 1))
        port=$((2200 + idx))
        install_host_key "$port"
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
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store issue-client dev-02 dev 11
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store issue-client admin-01 sysadmin 20
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store issue-client gw-sucursal sucursal 30
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store export-server /tmp/gw-vpn-bundle
        for c in dev-01 dev-02 admin-01 gw-sucursal; do
            bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store export-client \$c /tmp/\$c.ovpn
        done
        chown -R $GUEST_USER:$GUEST_USER /tmp/gw-vpn-bundle /tmp/*.ovpn
    '"
    rm -rf "$BUNDLES_DIR/gw-vpn-bundle"
    scp_nat 2203 -r "$GUEST_USER@127.0.0.1:/tmp/gw-vpn-bundle" "$BUNDLES_DIR/gw-vpn-bundle"
    scp_nat 2203 "$GUEST_USER@127.0.0.1:/tmp/dev-01.ovpn" "$PROFILES_DIR/dev-01.ovpn"
    scp_nat 2203 "$GUEST_USER@127.0.0.1:/tmp/dev-02.ovpn" "$PROFILES_DIR/dev-02.ovpn"
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
        install -D -m 644 /home/$GUEST_USER/Redes-TPE/infra/remote-access/clients/cli-adm/openvpn-restart.conf /etc/systemd/system/openvpn-client@the-store.service.d/restart.conf
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
        set -e
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/provision/k8s-node.sh /tmp/sysadmin_ed25519.pub $MAC_K8S_NODE_LAN
        usermod -aG docker $GUEST_USER
        install -m 600 /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/nat-temporal.yaml /etc/netplan/91-nat-temporal.yaml
        netplan apply
        # La ruta por defecto de gw-vpn (sin Internet) le gana a la del NAT: se descarta mientras se instala.
        /lib/systemd/systemd-networkd-wait-online -i eth0 -i enp0s3 --timeout=60
        ip route del default via 10.10.0.1 dev eth0
        curl -fsS -m 5 -o /dev/null https://kind.sigs.k8s.io
        [[ -x /usr/local/bin/kind ]] || curl -fsSL -o /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
        [[ -x /usr/local/bin/kubectl ]] || curl -fsSL -o /usr/local/bin/kubectl https://dl.k8s.io/release/v1.32.2/bin/linux/amd64/kubectl
        chmod +x /usr/local/bin/kind /usr/local/bin/kubectl
        su - $GUEST_USER -c \"cd /home/$GUEST_USER/Redes-TPE && ./local.sh create-cluster --remote-access --skip-tests\"
        docker update --restart=unless-stopped the-store-control-plane
        su - $GUEST_USER -c \"cd /home/$GUEST_USER/Redes-TPE && REQUIRE_CLUSTER=1 bash infra/remote-access/tests/kubernetes.sh\"
        su - $GUEST_USER -c \"cd /home/$GUEST_USER/Redes-TPE && bash infra/remote-access/scripts/sysadmin-kubeconfig.sh /tmp/sysadmin.kubeconfig\"
        rm -f /etc/netplan/91-nat-temporal.yaml
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
    banner "LABORATORIO DESPLEGADO Y SNAPSHOTEADO"
}

[[ "${2:-}" == "--no-pause" ]] && NO_PAUSE=1

ACTION=${1:-}
if [[ -z "$ACTION" && -t 0 ]]; then
    banner "MENÚ INTERACTIVO — LABORATORIO VIRTUALBOX (REDES-TPE)"
    echo "  1) status      - Ver estado de redes, VMs, túneles VPN y pods K8s"
    echo "  2) verify      - Ejecutar pruebas integrales punta a punta (CA, Sysadmin, K8s, Sucursal)"
    echo "  3) reset-demo  - Apagar VMs, restaurar snapshot 'demo', iniciar y verificar"
    echo "  4) start       - Iniciar las 6 VMs en segundo plano"
    echo "  5) stop        - Apagar las 6 VMs"
    echo "  6) full        - Desplegar los Pasos 1 a 8 desde cero"
    echo "  7) eval        - Simular la corrección de la defensa (CU1..CU6)"
    echo ""
    printf "Elegí una opción [1-7 o nombre, Enter=1 (status)]: "
    read -r choice || true
    case "${choice:-1}" in
        1|status)     ACTION="status" ;;
        2|verify)     ACTION="verify" ;;
        3|reset-demo) ACTION="reset-demo" ;;
        4|start)      ACTION="start" ;;
        5|stop)       ACTION="stop" ;;
        6|full)       ACTION="full" ;;
        7|eval)       ACTION="eval" ;;
        *)            ACTION="$choice" ;;
    esac
elif [[ -z "$ACTION" ]]; then
    ACTION="status"
fi

case "$ACTION" in
    full|provision)     cmd_full ;;
    status)             cmd_status ;;
    verify|test)        cmd_verify ;;
    reset-demo|restore) cmd_reset_demo ;;
    start)              start_all_vms; wait_for_offline_hosts ;;
    stop)               stop_all_vms ;;
    eval|profesor)      bash "$SCRIPT_DIR/eval.sh" --no-pause ;;
    *)
        echo "Uso: $0 {status|verify|reset-demo|start|stop|full|eval}" >&2
        exit 1
        ;;
esac

