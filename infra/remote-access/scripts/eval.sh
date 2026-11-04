#!/usr/bin/env bash
# Evaluación automática de CU1..CU6: restaura el snapshot 'demo' al empezar y al terminar.
# Uso: eval.sh [--no-pause]  (o: setup-lab.sh eval)

set -euo pipefail

LOG_NAME="eval"
source "$(dirname "${BASH_SOURCE[0]}")/lab-common.sh"
[[ "${1:-}" == "--no-pause" ]] && NO_PAUSE=1

TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

substep() { log_out "\n${C_BOLD}${C_YELLOW}>>> $*${C_RESET}\n"; }
info()    { log_out "    ${C_BLUE}[INFO]${C_RESET} $*\n"; }

pass_check() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    log_out "$(printf "    ${C_GREEN}[APROBADO #%02d]${C_RESET} %s" "$TOTAL_CHECKS" "$*")\n"
}

fail_check() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    log_out "$(printf "    ${C_RED}[FALLO #%02d]${C_RESET} %s" "$TOTAL_CHECKS" "$*")\n"
}

scp_ip() { scp "${SSH_OPTS[@]}" "$@"; }

DEV_LABEL="dev-ns"
dev_run() { ssh_ip "$CLI" "echo '$GUEST_PASS' | sudo -S -p '' ip netns exec dev-ns bash -c $(printf %q "$1")" 2>&1 </dev/null; }

resolve_check() {
    if (( $1 == 0 )); then
        pass_check "$2"
    else
        fail_check "$3"
        log_out "$(printf '%s' "$CHK_TRACE" | sed 's/^/        /')\n"
    fi
    CHK_TRACE=""
}

run_evaluation() {
    local rc

    banner "SIMULACIÓN DE EVALUACIÓN Y CORRECCIÓN DEL PROFESOR — REDES TPE"

    banner "ETAPA 0: RESTAURACIÓN DE SNAPSHOT 'demo' Y VERIFICACIÓN DE AISLAMIENTO OFFLINE"

    substep "0.1 Verificando o restaurando el snapshot 'demo' en las 6 VMs..."
    if [[ $("$VBOX" list runningvms | wc -l) -eq 6 ]] && ssh_ip 192.168.100.20 "echo $GUEST_PASS | sudo -S test -f /root/ca-store/ccd/dev-01" 2>/dev/null; then
        info "Las 6 VMs ya están encendidas en el estado limpio del snapshot 'demo'."
    else
        bash "$SCRIPT_DIR/setup-lab.sh" reset-demo --no-pause
    fi

    substep "0.2 Verificando que ninguna de las 6 VMs tenga interfaz NAT conectada a Internet..."
    local offline_ok=1 vm nic1
    for vm in "${ALL_VMS[@]}"; do
        nic1=$("$VBOX" showvminfo "$vm" --machinereadable | tr -d '\r' | sed -n 's/^nic1="\(.*\)"/\1/p')
        info "VM '$vm' -> nic1=\"$nic1\""
        [[ "$nic1" == "none" ]] || offline_ok=0
    done
    if [[ "$offline_ok" -eq 1 ]]; then
        pass_check "Las 6 VMs tienen NIC 1 deshabilitada (nic1=none, sin Internet)."
    else
        fail_check "Alguna VM aún tiene NIC 1 habilitada."
    fi

    banner "ESCENARIO 1 (CU1): SEGURIDAD EN SEGMENTO NO CONFIABLE (WAN) Y HARDENING"

    substep "1.1 Escaneo TCP desde la WAN (203.0.113.51) a SSH, DNS, HTTP, HTTPS, OpenVPN y API de Kubernetes de gw-vpn (203.0.113.10)..."
    rc=0
    chk_wan_tcp_filtered || rc=1
    resolve_check "$rc" "gw-vpn no responde en ningún puerto TCP escaneado desde la WAN (22, 53, 80, 443, 1194 y 6443 filtrados)." \
        "gw-vpn respondió en algún puerto TCP desde la WAN."

    substep "1.2 Verificando registro de auditoría (nftables log) en gw-vpn ante intento de SSH desde WAN..."
    rc=0
    chk_drop_logged input "$CLI" 203.0.113.10 22 || rc=1
    resolve_check "$rc" "nftables registra en el kernel los paquetes descartados en INPUT ('the-store input drop:')." \
        "No se encontró el log 'the-store input drop:' en dmesg de gw-vpn."

    substep "1.3 Intento de saltear la VPN: acceso a la LAN sin ruta y con una ruta manual hacia 10.10.0.0/16 vía 203.0.113.10..."
    rc=0
    chk_lan_blocked_no_route 10.10.10.99 || rc=1
    chk_lan_blocked_with_route 10.10.10.99 || rc=1
    resolve_check "$rc" "El tráfico directo desde WAN hacia la LAN interna (sin túnel VPN) es bloqueado por gw-vpn y queda registrado." \
        "Se logró alcanzar la LAN interna desde WAN sin túnel."

    substep "1.4 Sondeo UDP a 203.0.113.10:1194 sin clave tls-crypt (Stealth OpenVPN)..."
    rc=0
    chk_wan_udp_silent || rc=1
    resolve_check "$rc" "OpenVPN con tls-crypt descarta silenciosamente paquetes UDP no autenticados en 1194." \
        "OpenVPN respondió a un paquete UDP sin tls-crypt."

    substep "1.5 Verificando endurecimiento de servicios en gw-vpn (usuario nobody, sshd solo en gestión)..."
    rc=0
    chk_gw_hardening || rc=1
    resolve_check "$rc" "OpenVPN corre sin privilegios (nobody) y sshd escucha únicamente en 192.168.100.1:22." \
        "Configuración de privilegios de OpenVPN o de sshd incorrecta."

    banner "ESCENARIO 2 (CU2, CU3 y CU5): DESARROLLADOR (dev-01, 10.8.0.10)"

    substep "2.1 Levantando cliente 'dev-01' (10.8.0.10) en un namespace de red aislado (en paralelo con admin-01 y gw-sucursal)..."
    scp_ip "$PROFILES_DIR/dev-01.ovpn" "$GUEST_USER@203.0.113.51:/tmp/dev-01.ovpn"
    ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S bash -c '
        if ! ip netns exec dev-ns ip -4 addr show dev tun0 2>/dev/null | grep -q 10.8.0.10; then
            kill \$(cat /run/dev-eval.pid 2>/dev/null) 2>/dev/null || true
            sleep 1
            ip netns del dev-ns 2>/dev/null || true
            ip link del veth-host 2>/dev/null || true
            ip netns add dev-ns
            ip link add veth-host type veth peer name veth-dev netns dev-ns
            ip addr add 10.99.0.1/24 dev veth-host
            ip link set veth-host up
            ip netns exec dev-ns ip link set lo up
            ip netns exec dev-ns ip addr add 10.99.0.2/24 dev veth-dev
            ip netns exec dev-ns ip link set veth-dev up
            ip netns exec dev-ns ip route add default via 10.99.0.1
            sysctl -qw net.ipv4.ip_forward=1
            if command -v iptables >/dev/null 2>&1; then
                iptables -t nat -C POSTROUTING -s 10.99.0.0/24 -o eth0 -j MASQUERADE 2>/dev/null || \
                    iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -o eth0 -j MASQUERADE
            else
                nft add table ip evalnat 2>/dev/null || true
                nft flush table ip evalnat
                nft add chain ip evalnat postrouting \"{ type nat hook postrouting priority srcnat; policy accept; }\"
                nft add rule ip evalnat postrouting ip saddr 10.99.0.0/24 oifname \"eth0\" masquerade
            fi
            mkdir -p /etc/netns/dev-ns
            echo \"nameserver 10.8.0.1\" > /etc/netns/dev-ns/resolv.conf
            ip netns exec dev-ns openvpn --config /tmp/dev-01.ovpn --daemon dev-eval --writepid /run/dev-eval.pid --log /tmp/dev-eval.log
            for i in {1..20}; do
                if ip netns exec dev-ns ip -4 addr show dev tun0 2>/dev/null | grep -q 10.8.0.10; then
                    break
                fi
                sleep 1
            done
        fi
    '"

    local dev_ip dev_routes
    dev_ip=$(ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S ip netns exec dev-ns ip -4 -br addr show dev tun0")
    dev_routes=$(ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S ip netns exec dev-ns ip -4 route show")
    info "Interfaz tun0 de dev-01: $dev_ip"
    info "Tabla de ruteo de dev-01:"
    echo "$dev_routes" | sed 's/^/        /'
    rc=0
    chk_dev_enrollment dev-01 10.8.0.10 || rc=1
    { echo "$dev_ip" | grep -q "10.8.0.10/24" && echo "$dev_routes" | grep -q "^10.10.10.5 via 10.8.0.1 dev tun0"; } || rc=1
    resolve_check "$rc" "dev-01 tiene su certificado y CCD en la CA, y recibió IP fija 10.8.0.10/24 y ruta split-tunnel únicamente hacia 10.10.10.5." \
        "El certificado o CCD de dev-01 en la CA, o la IP o ruta que recibió, no son los esperados."

    substep "2.2 CU5: resolución DNS interna (10.8.0.1) desde dev-01 y rechazo de dominios externos..."
    local dns_ui dns_ext
    dns_ui=$(ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S ip netns exec dev-ns dig +short @10.8.0.1 ui.the-store.internal")
    dns_ext=$(ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S ip netns exec dev-ns dig @10.8.0.1 example.com | grep -o 'status: [A-Z]*'")
    info "Consulta DNS ui.the-store.internal -> $dns_ui"
    info "Consulta DNS example.com           -> $dns_ext"
    if [[ "$dns_ui" == "10.10.10.5" && "$dns_ext" == "status: REFUSED" ]]; then
        pass_check "dnsmasq en gw-vpn (10.8.0.1) resuelve *.the-store.internal a 10.10.10.5 y devuelve REFUSED para dominios externos."
    else
        fail_check "Comportamiento inesperado del DNS en 10.8.0.1."
    fi

    substep "2.3 Flujo de compra real en los microservicios desde dev-01 (10.8.0.10)..."
    rc=0
    chk_dev_app eval-profesor || rc=1
    resolve_check "$rc" "dev-01 operó exitosamente sobre Catalog, Carts y UI a través del Ingress interno (10.10.10.5:80)." \
        "Fallo al operar sobre los microservicios desde dev-01."

    substep "2.4 CU3: bloqueo de firewall (nftables) para dev-01 (10.8.0.10) hacia SSH (22), API K8s (6443) y Gestión..."
    rc=0
    chk_role_rules dev-01 || rc=1
    chk_dev_ports || rc=1
    chk_dev_gateway_blocked || rc=1
    chk_drop_logged forward 10.8.0.10 10.10.10.5 '22|6443' || rc=1
    resolve_check "$rc" "Las reglas nftables por rol y el firewall bloquean a dev-01 (10.8.0.10) el acceso a SSH (22), K8s API (6443) y SSH del gateway, auditando el intento." \
        "Las reglas por rol no son las esperadas o dev-01 pudo alcanzar un puerto administrativo restringido."

    substep "2.5 CU5: el HTTP de dev-01 viaja cifrado por la WAN y en claro por la LAN interna (captura simultánea en gw-vpn)..."
    cap_start 10 "eth0|udp port 1194|/tmp/eval-wan.cap" "eth1|tcp port 80|/tmp/eval-lan.cap"
    sleep 3
    probe_dev "for i in 1 2 3; do curl -fsS --max-time 5 http://ui.the-store.internal/ >/dev/null; done"
    wait
    rc=0
    chk_wan_encrypted /tmp/eval-wan.cap "$CLI" || rc=1
    chk_lan_clear /tmp/eval-lan.cap || rc=1
    cap_rm /tmp/eval-wan.cap /tmp/eval-lan.cap
    resolve_check "$rc" "En la WAN solo se ve UDP/1194 cifrado (sin nombres ni HTTP) y en la LAN interna (eth1) el mismo tráfico aparece en claro." \
        "La captura no mostró tráfico cifrado en la WAN y HTTP en claro en la LAN."

    banner "ESCENARIO 3 (CU3): SYSADMIN (admin-01, 10.8.0.20) — ADMINISTRACIÓN Y MENOR PRIVILEGIO (RBAC)"

    substep "3.1 Acceso SSH como root@10.10.10.5 desde cli-adm (10.8.0.20) con clave ed25519..."
    rc=0
    chk_sysadmin_ssh_node || rc=1
    resolve_check "$rc" "Sysadmin (10.8.0.20) accede por SSH como root@10.10.10.5 y administra el nodo." \
        "Sysadmin no pudo administrar k8s-node por SSH."

    substep "3.2 Operaciones permitidas por RBAC en Kubernetes (listar pods y leer logs en namespace 'the-store')..."
    rc=0
    chk_sysadmin_k8s_read || rc=1
    resolve_check "$rc" "Sysadmin puede listar recursos y consultar logs de pods en el namespace 'the-store'." \
        "Sysadmin no pudo listar pods o leer logs en 'the-store'."

    substep "3.3 Verificando restricciones de Menor Privilegio (RBAC Denegado: Secrets, exec, delete pods, kube-system)..."
    rc=0
    chk_sysadmin_rbac || rc=1
    resolve_check "$rc" "RBAC de Kubernetes aplica principio de menor privilegio (prohíbe Secrets, exec, delete y otros namespaces)." \
        "Alguna restricción RBAC no se aplicó correctamente."

    substep "3.4 Verificando que el Sysadmin (10.8.0.20) NO tiene acceso SSH a gw-vpn (10.8.0.1) ni a la CA (192.168.100.20)..."
    rc=0
    chk_sysadmin_isolated || rc=1
    resolve_check "$rc" "El Sysadmin está aislado de la administración del Gateway VPN y de la Autoridad Certificante (CA)." \
        "El Sysadmin pudo alcanzar SSH del Gateway o de la CA."

    banner "ESCENARIO 4 (CU6, SUCURSAL SITE-TO-SITE): HOST DE SUCURSAL (172.16.20.10 -> 10.8.0.30)"

    substep "4.1 Verificando el túnel y la ruta de gw-sucursal en gw-vpn, y desde 'host-suc' (172.16.20.10) ausencia de cliente VPN, acceso HTTP por nombre y bloqueo de puertos..."
    rc=0
    chk_branch_tunnel || rc=1
    chk_branch_host || rc=1
    timeout 3 "$VBOX" guestcontrol host-suc closesession --all </dev/null >/dev/null 2>&1 || true
    resolve_check "$rc" "La LAN de sucursal (172.16.20.10) accede transparentemente al Ingress por el túnel site-to-site y tiene bloqueados SSH/API." \
        "Fallo en las validaciones de la sucursal."

    banner "ESCENARIO 5 (CU4): REVOCACIÓN EN CALIENTE DE 'dev-01' DESDE LA CA Y CORTE INMEDIATO"

    substep "5.1 Verificando que ANTES de revocar están los 3 clientes conectados en gw-vpn (dev-01, admin-01 y gw-sucursal)..."
    rc=0
    chk_clients_connected "Están conectados dev-01, admin-01 y gw-sucursal" dev-01 admin-01 gw-sucursal || rc=1
    resolve_check "$rc" "Los 3 perfiles (dev-01 en .10, admin-01 en .20 y gw-sucursal en .30) están conectados simultáneamente." \
        "No estaban los 3 clientes conectados antes de la revocación."

    substep "5.2 Ejecutando en 'ca' (192.168.100.20): 'pki.sh revoke dev-01' y 'pki.sh publish-crl dev-01'..."
    sync_clocks
    rc=0
    chk_revoke dev-01 || rc=1
    chk_publish_crl dev-01 || rc=1
    resolve_check "$rc" "La CA revocó a dev-01, instaló la CRL en gw-vpn por la red de gestión y mató la sesión activa de dev-01." \
        "La publicación de CRL o el cierre de sesión de dev-01 no devolvió el resultado esperado."

    substep "5.3 Verificando que 'dev-01' fue expulsado y NO puede reconectar, mientras 'admin-01' y 'gw-sucursal' siguen conectados..."
    rc=0
    chk_revoked_gone dev-01 admin-01 gw-sucursal || rc=1
    resolve_check "$rc" "dev-01 fue desconectado inmediatamente sin interrumpir las sesiones de admin-01 ni gw-sucursal." \
        "El estado de sesiones en gw-vpn tras la revocación es incorrecto."

    substep "5.4 Intentando reconectar con el certificado revocado 'dev-01.ovpn' y verificando rechazo por CRL en gw-vpn..."
    ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S bash -c '
        kill \$(cat /run/dev-eval.pid 2>/dev/null) 2>/dev/null || true
        sleep 1
    '"
    rc=0
    chk_revoked_rejected dev-01 || rc=1
    ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S bash -c '
        ip netns del dev-ns 2>/dev/null || true
        ip link del veth-host 2>/dev/null || true
        rm -f /tmp/dev-01.ovpn /tmp/dev-eval.log
    '"
    resolve_check "$rc" "gw-vpn rechaza cualquier intento de reconexión de dev-01 verificando la CRL actualizada." \
        "No se registró el rechazo por CRL en los logs de gw-vpn."

    banner "ETAPA FINAL: RESTAURACIÓN DEL SNAPSHOT 'demo' PARA DEJAR EL LABORATORIO LIMPIO"
    bash "$SCRIPT_DIR/setup-lab.sh" stop --no-pause
    substep "Restaurando snapshot 'demo' en las 6 VMs con 'virtualbox.sh restore'..."
    bash "$SCRIPT_DIR/virtualbox.sh" restore </dev/null
    substep "Reiniciando las 6 VMs en segundo plano para dejarlas listas..."
    for vm in "${ALL_VMS[@]}"; do
        info "Encendiendo VM '$vm'..."
        "$VBOX" startvm "$vm" --type headless </dev/null >/dev/null 2>&1
        sleep 1
    done
    info "Snapshot 'demo' restaurado y las 6 VMs iniciadas (dev-01 vuelve a estar habilitado)."

    banner "RESULTADO FINAL DE LA EVALUACIÓN DEL PROFESOR"
    log_out "  Controles evaluados : $TOTAL_CHECKS\n"
    log_out "  Controles aprobados : ${C_GREEN}$PASSED_CHECKS${C_RESET}\n"
    log_out "  Controles fallidos  : ${C_RED}$FAILED_CHECKS${C_RESET}\n"
    if [[ "$FAILED_CHECKS" -eq 0 ]]; then
        log_out "\n  ${C_BOLD}${C_GREEN}TODOS LOS CONTROLES APROBADOS (CU1..CU6)${C_RESET}\n"
    else
        log_out "\n  ${C_BOLD}${C_RED}ATENCIÓN: Se detectaron $FAILED_CHECKS controles fallidos.${C_RESET}\n"
        return 1
    fi
}

run_evaluation
