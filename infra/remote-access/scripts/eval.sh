#!/usr/bin/env bash
# Simula la corrección de la defensa contra el laboratorio (CU1..CU6). Restaura el snapshot 'demo'
# al empezar y al terminar. Uso: eval.sh [--no-pause]  (o: setup-lab.sh eval)

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

run_evaluation() {
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

    substep "1.1 Escaneo/conexión desde WAN (203.0.113.51) hacia SSH y HTTP de gw-vpn (203.0.113.10)..."
    if ssh_ip 203.0.113.51 "! timeout 2 bash -c 'true </dev/tcp/203.0.113.10/22' 2>/dev/null && ! timeout 2 bash -c 'true </dev/tcp/203.0.113.10/80' 2>/dev/null"; then
        pass_check "gw-vpn rechaza/descarta conexiones TCP 22 (SSH) y 80 (HTTP) desde la WAN (203.0.113.0/24)."
    else
        fail_check "gw-vpn aceptó conexiones indebidas desde la WAN."
    fi

    substep "1.2 Verificando registro de auditoría (nftables log) en gw-vpn ante intento de SSH desde WAN..."
    local drop_log
    drop_log=$(ssh_ip 192.168.100.1 "echo $GUEST_PASS | sudo -S dmesg | grep 'the-store input drop:.*SRC=203.0.113.51 DST=203.0.113.10.*DPT=22' | tail -n 1 || true")
    if [[ -n "$drop_log" ]]; then
        info "Log en gw-vpn: $drop_log"
        pass_check "nftables registra en el kernel los paquetes descartados en INPUT ('the-store input drop:')."
    else
        fail_check "No se encontró el log 'the-store input drop:' en dmesg de gw-vpn."
    fi

    substep "1.3 Intento de saltear la VPN agregando una ruta manual hacia 10.10.0.0/16 vía 203.0.113.10..."
    if ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S bash -c '
        ip route add 10.10.10.99/32 via 203.0.113.10 dev eth0
        trap \"ip route del 10.10.10.99/32 via 203.0.113.10 dev eth0 2>/dev/null || true\" EXIT
        ! timeout 2 bash -c \"true </dev/tcp/10.10.10.99/80\" 2>/dev/null
    '"; then
        pass_check "El tráfico directo desde WAN hacia la LAN interna (sin túnel VPN) es bloqueado por gw-vpn."
    else
        fail_check "Se logró alcanzar la LAN interna desde WAN sin túnel."
    fi

    substep "1.4 Sondeo UDP a 203.0.113.10:1194 sin clave tls-crypt (Stealth OpenVPN)..."
    local udp_reply
    udp_reply=$(ssh_ip 203.0.113.51 "timeout 2 bash -c 'echo -n PROBE_SIN_TLS_CRYPT | socat -T 1 - UDP4:203.0.113.10:1194' 2>/dev/null | wc -c")
    info "Bytes recibidos de 203.0.113.10:1194 ante paquete sin tls-crypt: $udp_reply"
    if [[ "$udp_reply" -eq 0 ]]; then
        pass_check "OpenVPN con tls-crypt descarta silenciosamente paquetes UDP no autenticados en 1194."
    else
        fail_check "OpenVPN respondió a un paquete UDP sin tls-crypt."
    fi

    substep "1.5 Verificando endurecimiento de servicios en gw-vpn (usuario nobody, socket root, sshd solo en gestión)..."
    local ovpn_user sshd_listen
    ovpn_user=$(ssh_ip 192.168.100.1 "ps -C openvpn -o user= | head -n 1 | tr -d ' '")
    sshd_listen=$(ssh_ip 192.168.100.1 "echo $GUEST_PASS | sudo -S ss -tlnp | grep sshd | awk '{print \$4}'")
    info "Usuario del proceso openvpn en gw-vpn: $ovpn_user"
    info "Socket de escucha de sshd en gw-vpn:   $sshd_listen"
    if [[ "$ovpn_user" == "nobody" && "$sshd_listen" == "192.168.100.1:22" ]]; then
        pass_check "OpenVPN corre sin privilegios (nobody) y sshd escucha únicamente en 192.168.100.1:22."
    else
        fail_check "Configuración de privilegios de OpenVPN ($ovpn_user) o sshd ($sshd_listen) incorrecta."
    fi

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
    if echo "$dev_ip" | grep -q "10.8.0.10/24" && echo "$dev_routes" | grep -q "^10.10.10.5 via 10.8.0.1 dev tun0"; then
        pass_check "dev-01 recibió IP fija 10.8.0.10/24 por CCD y ruta split-tunnel únicamente hacia 10.10.10.5."
    else
        fail_check "dev-01 no recibió la IP o ruta esperada."
    fi

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
    local catalog_json cart_get ui_title
    catalog_json=$(ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S ip netns exec dev-ns curl -fsS --max-time 10 http://catalog.the-store.internal/catalog/products")
    info "Catálogo obtenido desde http://catalog.the-store.internal/catalog/products (primeros 160 chars):"
    echo "        ${catalog_json:0:160}..."
    ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S ip netns exec dev-ns curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' -d '{\"itemId\":\"a1258cd2-176c-4507-ade6-746dab5ad625\",\"unitPrice\":199,\"quantity\":2}' http://carts.the-store.internal/carts/eval-profesor/items" >/dev/null
    cart_get=$(ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S ip netns exec dev-ns curl -fsS --max-time 10 http://carts.the-store.internal/carts/eval-profesor/items")
    info "Ítem 'Aqua Ace GT' agregado y consultado en http://carts.the-store.internal/carts/eval-profesor/items:"
    echo "        $cart_get"
    ui_title=$(ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S ip netns exec dev-ns curl -fsS --max-time 10 http://ui.the-store.internal/home | grep -i '<title>' | tr -d '\r\n' || true")
    info "Título renderizado por http://ui.the-store.internal/home: $ui_title"
    if [[ "$catalog_json" == *"a1258cd2-176c-4507-ade6-746dab5ad625"* && "$cart_get" == *"a1258cd2-176c-4507-ade6-746dab5ad625"* && -n "$ui_title" ]]; then
        pass_check "dev-01 operó exitosamente sobre Catalog, Carts y UI a través del Ingress interno (10.10.10.5:80)."
    else
        fail_check "Fallo al operar sobre los microservicios desde dev-01."
    fi

    substep "2.4 CU3: bloqueo de firewall (nftables) para dev-01 (10.8.0.10) hacia SSH (22), API K8s (6443) y Gestión..."
    if ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S ip netns exec dev-ns bash -c '
        ! timeout 2 bash -c \"true </dev/tcp/10.10.10.5/22\" 2>/dev/null &&
        ! timeout 2 bash -c \"true </dev/tcp/10.10.10.5/6443\" 2>/dev/null &&
        ! timeout 2 bash -c \"true </dev/tcp/10.8.0.1/22\" 2>/dev/null
    '"; then
        local fwd_drop
        fwd_drop=$(ssh_ip 192.168.100.1 "echo $GUEST_PASS | sudo -S dmesg | grep 'the-store forward drop:.*SRC=10.8.0.10 DST=10.10.10.5.*DPT=6443' | tail -n 1 || true")
        info "Log de bloqueo en gw-vpn: $fwd_drop"
        pass_check "Firewall bloquea a dev-01 (10.8.0.10) el acceso a SSH (22), K8s API (6443) y SSH del gateway, auditando el intento."
    else
        fail_check "dev-01 pudo alcanzar un puerto administrativo restringido."
    fi

    substep "2.5 CU5: el HTTP de dev-01 viaja cifrado por la WAN y en claro por la LAN interna (captura simultánea en gw-vpn)..."
    local wan_cap lan_cap wan_pkts
    wan_cap=$(mktemp)
    lan_cap=$(mktemp)
    ssh_ip 192.168.100.1 "echo $GUEST_PASS | sudo -S timeout 10 tcpdump -ni eth0 -A -l udp port 1194 2>/dev/null" > "$wan_cap" 2>/dev/null &
    ssh_ip 192.168.100.1 "echo $GUEST_PASS | sudo -S timeout 10 tcpdump -ni eth1 -A -l tcp port 80 2>/dev/null" > "$lan_cap" 2>/dev/null &
    sleep 3
    ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S ip netns exec dev-ns bash -c 'for i in 1 2 3; do curl -fsS --max-time 5 http://ui.the-store.internal/ >/dev/null; done'" || true
    wait
    wan_pkts=$(grep -c 'UDP, length' "$wan_cap" || true)
    info "Datagramas UDP/1194 vistos en la WAN (eth0 de gw-vpn): $wan_pkts"
    if [[ "$wan_pkts" -gt 0 ]] && ! grep -q 'the-store.internal' "$wan_cap" && grep -q 'Host: ui.the-store.internal' "$lan_cap"; then
        pass_check "En la WAN solo se ve UDP/1194 cifrado (sin nombres ni HTTP) y en la LAN interna (eth1) el mismo tráfico aparece en claro."
    else
        fail_check "La captura no mostró tráfico cifrado en la WAN y HTTP en claro en la LAN."
    fi
    rm -f "$wan_cap" "$lan_cap"

    banner "ESCENARIO 3 (CU3): SYSADMIN (admin-01, 10.8.0.20) — ADMINISTRACIÓN Y MENOR PRIVILEGIO (RBAC)"

    substep "3.1 Acceso SSH como root@10.10.10.5 desde cli-adm (10.8.0.20) con clave ed25519..."
    local k8s_info
    k8s_info=$(ssh_ip 203.0.113.51 "ssh -o StrictHostKeyChecking=no root@10.10.10.5 'echo \"Hostname: \$(hostname) | Kernel: \$(uname -r) | Contenedor Kind: \$(docker ps --format {{.Names}}:{{.Status}})\"'")
    info "$k8s_info"
    if [[ "$k8s_info" == *"Hostname: k8s-node"* && "$k8s_info" == *"the-store-control-plane"* ]]; then
        pass_check "Sysadmin (10.8.0.20) accede por SSH como root@10.10.10.5 y administra el nodo."
    else
        fail_check "Sysadmin no pudo administrar k8s-node por SSH."
    fi

    substep "3.2 Operaciones permitidas por RBAC en Kubernetes (listar pods y leer logs en namespace 'the-store')..."
    local pods_out logs_out
    pods_out=$(ssh_ip 203.0.113.51 "kubectl get pods -n the-store --no-headers | wc -l")
    logs_out=$(ssh_ip 203.0.113.51 "kubectl logs -n the-store deployment/catalog --tail=2")
    info "Cantidad de pods activos en namespace 'the-store': $pods_out"
    info "Últimas líneas de log de deployment/catalog:"
    echo "$logs_out" | sed 's/^/        /'
    if [[ "$pods_out" -ge 5 && -n "$logs_out" ]]; then
        pass_check "Sysadmin puede listar recursos y consultar logs de pods en el namespace 'the-store'."
    else
        fail_check "Sysadmin no pudo listar pods o leer logs en 'the-store'."
    fi

    substep "3.3 Verificando restricciones de Menor Privilegio (RBAC Denegado: Secrets, exec, delete pods, kube-system)..."
    local rbac_ok=1
    for cmd_desc in \
        "get secrets -n the-store:Lectura de Secrets en the-store" \
        "get pods -n kube-system:Listado de pods en kube-system" \
        "delete pod --all -n the-store --dry-run=server:Eliminación de pods en the-store"
    do
        local kcmd=${cmd_desc%%:*}
        local desc=${cmd_desc##*:}
        local out
        if out=$(ssh_ip 203.0.113.51 "kubectl $kcmd 2>&1"); then
            fail_check "RBAC permitió indebidamente: $desc"
            rbac_ok=0
        else
            info "Denegado correctamente ($desc): $(echo "$out" | head -n 1)"
        fi
    done
    local can_exec
    can_exec=$(ssh_ip 203.0.113.51 "kubectl auth can-i create pods --subresource=exec -n the-store || true")
    info "¿Puede hacer 'kubectl exec' en pods?: $can_exec"
    if [[ "$rbac_ok" -eq 1 && "$can_exec" == "no" ]]; then
        pass_check "RBAC de Kubernetes aplica principio de menor privilegio (prohíbe Secrets, exec, delete y otros namespaces)."
    else
        fail_check "Alguna restricción RBAC no se aplicó correctamente."
    fi

    substep "3.4 Verificando que el Sysadmin (10.8.0.20) NO tiene acceso SSH a gw-vpn (10.8.0.1) ni a la CA (192.168.100.20)..."
    if ssh_ip 203.0.113.51 "! timeout 2 bash -c 'true </dev/tcp/10.8.0.1/22' 2>/dev/null && ! timeout 2 bash -c 'true </dev/tcp/192.168.100.20/22' 2>/dev/null"; then
        pass_check "El Sysadmin está aislado de la administración del Gateway VPN y de la Autoridad Certificante (CA)."
    else
        fail_check "El Sysadmin pudo alcanzar SSH del Gateway o de la CA."
    fi

    banner "ESCENARIO 4 (CU6, SUCURSAL SITE-TO-SITE): HOST DE SUCURSAL (172.16.20.10 -> 10.8.0.30)"

    substep "4.1 Verificando desde 'host-suc' (172.16.20.10) ausencia de cliente VPN local, DNS split-horizon, acceso HTTP y bloqueo de puertos..."
    local branch_out
    branch_out=$(MSYS2_ARG_CONV_EXCL="*" "$VBOX" guestcontrol host-suc run --exe /bin/bash --username "$GUEST_USER" --password "$GUEST_PASS" -- -c '
        set -euo pipefail
        ! pgrep -x openvpn >/dev/null || { echo "FALLO: openvpn corriendo en host-suc"; exit 1; }
        echo "INTERFACES: $(ip -4 -br addr show dev eth0 | tr -s " ")"
        dns_in=$(dig +short @172.16.20.1 catalog.the-store.internal)
        dns_out=$(dig @172.16.20.1 google.com | grep -o "status: [A-Z]*")
        echo "DNS_INTERNO: catalog.the-store.internal -> $dns_in | DNS_EXTERNO: google.com -> $dns_out"
        [[ "$dns_in" == "10.10.10.5" && "$dns_out" == "status: REFUSED" ]] || exit 1
        for svc in ui carts orders; do
            curl -fsS --max-time 10 "http://${svc}.the-store.internal/actuator/health/readiness" >/dev/null
        done
        for svc in catalog checkout; do
            curl -fsS --max-time 10 "http://${svc}.the-store.internal/health" >/dev/null
        done
        echo "HTTP_SUCURSAL: 5/5 microservicios respondieron 200 OK"
        ! timeout 2 bash -c "true </dev/tcp/10.10.10.5/22" 2>/dev/null || exit 1
        ! timeout 2 bash -c "true </dev/tcp/10.10.10.5/6443" 2>/dev/null || exit 1
        ! timeout 2 bash -c "true </dev/tcp/172.16.20.1/22" 2>/dev/null || exit 1
        echo "FIREWALL_SUCURSAL: bloqueados 10.10.10.5:22, 10.10.10.5:6443 y 172.16.20.1:22"
    ')
    timeout 3 "$VBOX" guestcontrol host-suc closesession --all </dev/null >/dev/null 2>&1 || true
    echo "$branch_out" | sed 's/^/        /' | tee -a "$LOG_FILE"
    if [[ "$branch_out" == *"FIREWALL_SUCURSAL: bloqueados"* ]]; then
        pass_check "La LAN de sucursal (172.16.20.10) accede transparentemente al Ingress por el túnel site-to-site y tiene bloqueados SSH/API."
    else
        fail_check "Fallo en las validaciones de la sucursal."
    fi

    banner "ESCENARIO 5 (CU4): REVOCACIÓN EN CALIENTE DE 'dev-01' DESDE LA CA Y CORTE INMEDIATO"

    substep "5.1 Verificando que ANTES de revocar están los 3 clientes conectados en gw-vpn (dev-01, admin-01 y gw-sucursal)..."
    local status_before
    status_before=$(ssh_ip 192.168.100.1 "echo $GUEST_PASS | sudo -S bash -c \"(printf 'status 2\n'; sleep 0.3; printf 'quit\n') | socat - UNIX-CONNECT:/run/openvpn-server/the-store.sock\" | tr -d '\r' | grep '^CLIENT_LIST'")
    echo "$status_before" | sed 's/^/        /'
    if echo "$status_before" | grep -q "CLIENT_LIST,dev-01" && \
       echo "$status_before" | grep -q "CLIENT_LIST,admin-01" && \
       echo "$status_before" | grep -q "CLIENT_LIST,gw-sucursal"; then
        pass_check "Los 3 perfiles (dev-01 en .10, admin-01 en .20 y gw-sucursal en .30) están conectados simultáneamente."
    else
        fail_check "No estaban los 3 clientes conectados antes de la revocación."
    fi

    substep "5.2 Ejecutando en 'ca' (192.168.100.20): 'pki.sh revoke dev-01' y 'pki.sh publish-crl dev-01'..."
    local now_ts revoke_out
    now_ts=$(date -u +%s)
    ssh_ip 192.168.100.20 "echo $GUEST_PASS | sudo -S date -u -s '@$now_ts' >/dev/null 2>&1 || true"
    ssh_ip 192.168.100.1  "echo $GUEST_PASS | sudo -S date -u -s '@$now_ts' >/dev/null 2>&1 || true"
    revoke_out=$(ssh_ip 192.168.100.20 "echo $GUEST_PASS | sudo -S bash -c '
        export EASYRSA_PASSIN=pass:$CA_PASS
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store revoke dev-01
        sleep 2
        bash /home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh /root/ca-store publish-crl dev-01
    '" 2>&1 || true)
    echo "$revoke_out" | tail -n 6 | sed 's/^/        /'
    if [[ "$revoke_out" == *"CRL installed"* && "$revoke_out" == *"dev-01: session ended"* ]]; then
        pass_check "La CA revocó a dev-01, instaló la CRL en gw-vpn por la red de gestión y mató la sesión activa de dev-01."
    else
        fail_check "La publicación de CRL o el cierre de sesión de dev-01 no devolvió el resultado esperado."
    fi

    substep "5.3 Verificando que 'dev-01' fue expulsado y NO puede reconectar, mientras 'admin-01' y 'gw-sucursal' siguen conectados..."
    sleep 1
    local status_after
    status_after=$(ssh_ip 192.168.100.1 "echo $GUEST_PASS | sudo -S bash -c \"(printf 'status 2\n'; sleep 0.3; printf 'quit\n') | socat - UNIX-CONNECT:/run/openvpn-server/the-store.sock\" | tr -d '\r' | grep '^CLIENT_LIST'")
    info "Clientes activos en gw-vpn DESPUÉS de revocar a dev-01:"
    echo "$status_after" | sed 's/^/        /'
    if ! echo "$status_after" | grep -q "CLIENT_LIST,dev-01" && \
       echo "$status_after" | grep -q "CLIENT_LIST,admin-01" && \
       echo "$status_after" | grep -q "CLIENT_LIST,gw-sucursal"; then
        pass_check "dev-01 fue desconectado inmediatamente sin interrumpir las sesiones de admin-01 ni gw-sucursal."
    else
        fail_check "El estado de sesiones en gw-vpn tras la revocación es incorrecto."
    fi

    substep "5.4 Intentando reconectar con el certificado revocado 'dev-01.ovpn' y verificando rechazo por CRL en gw-vpn..."
    ssh_ip 203.0.113.51 "echo $GUEST_PASS | sudo -S bash -c '
        kill \$(cat /run/dev-eval.pid 2>/dev/null) 2>/dev/null || true
        sleep 1
        ip netns exec dev-ns openvpn --config /tmp/dev-01.ovpn --daemon dev-retry --writepid /run/dev-retry.pid --log /tmp/dev-retry.log
        sleep 4
        kill \$(cat /run/dev-retry.pid 2>/dev/null) 2>/dev/null || true
        ip netns del dev-ns 2>/dev/null || true
        ip link del veth-host 2>/dev/null || true
        rm -f /tmp/dev-01.ovpn /tmp/dev-eval.log /tmp/dev-retry.log
    '"
    local crl_log
    crl_log=$(ssh_ip 192.168.100.1 "echo $GUEST_PASS | sudo -S journalctl -u openvpn-server@the-store -n 50 --no-pager | grep -iE 'CRL|revoked' | tail -n 2 || true")
    info "Log de rechazo TLS/CRL en gw-vpn:"
    echo "$crl_log" | sed 's/^/        /'
    if [[ -n "$crl_log" ]]; then
        pass_check "gw-vpn rechaza cualquier intento de reconexión de dev-01 verificando la CRL actualizada."
    else
        fail_check "No se registró el rechazo por CRL en los logs de gw-vpn."
    fi

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
