#!/usr/bin/env bash
# Demostración guiada, caso por caso, con la salida real de cada comando y un veredicto [OK]/[FALLO].
# Uso: demo.sh [cu1|cu2|cu3|cu4|cu5|cu6|todo]. CU2 a CU5 conectan dev-02 solos desde una terminal de administrador; CU4 revoca (después: setup-lab.sh reset-demo).

set -euo pipefail

LOG_NAME="demo"
source "$(dirname "${BASH_SOURCE[0]}")/lab-common.sh"
NO_PAUSE=1

DEV_CLIENT=${DEV_CLIENT:-dev-02}
DEV_IP=${DEV_IP:-10.8.0.11}
DEV_IP_RE=${DEV_IP//./\\.}

OK=0
FALLOS=0
TUNEL_APAGADO=0

DEV_LABEL="host"
dev_run() { bash -c "$1" </dev/null; }
on_cmd() { printf "${C_GREEN}[%s]${C_RESET} \$ %s\n" "$1" "$2"; }
on_out() { printf '%s\n' "$CHK_OUT"; }
on_detail() {
    if (( $2 == 0 )); then
        OK=$((OK + 1))
        printf "    ${C_GREEN}[OK]${C_RESET} %s\n" "$1"
    else
        FALLOS=$((FALLOS + 1))
        printf "    ${C_RED}[FALLO]${C_RESET} %s%s\n" "$1" "${3:+ ($3)}"
    fi
}

corre() { "$@" || true; } # un chequeo que falla ya quedó marcado [FALLO]: la demo sigue

pausa() {
    [[ "${DEMO_AUTO:-0}" == 1 ]] && return 0
    read -r -p $'\n[Enter para continuar] ' _ || true
}

paso() { printf "\n${C_BOLD}${C_YELLOW}>>> %s${C_RESET}\n" "$*"; }
nota() { printf "    ${C_BLUE}%s${C_RESET}\n" "$*"; }

fin_caso() {
    local ok=$((OK - $2)) fallos=$((FALLOS - $3)) color=$C_GREEN
    (( fallos == 0 )) || color=$C_RED
    printf "\n${color}${C_BOLD}Resultado %s: %d correctas, %d fallidas${C_RESET}\n" "$1" "$ok" "$fallos"
}

tunel_arriba() { curl -s --noproxy '*' --max-time 4 -o /dev/null http://ui.the-store.internal/home; }

conecta_dev() {
    local gui="${PROGRAMFILES:-/c/Program Files}/OpenVPN/bin/openvpn-gui.exe" i
    tunel_arriba && return 0
    [[ -x "$gui" ]] || return 1
    if tasklist | grep -qi openvpn-gui; then "$gui" --command connect "$DEV_CLIENT"; else "$gui" --connect "$DEV_CLIENT" & fi
    for i in {1..20}; do tunel_arriba && return 0; sleep 1; done
    return 1
}

requiere_tunel() {
    conecta_dev </dev/null >/dev/null 2>&1 && return 0
    printf "${C_RED}Sin túnel: no se pudo conectar %s con OpenVPN GUI; conectalo a mano y repetí este caso.${C_RESET}\n" "$DEV_CLIENT"
    return 1
}

levanta_tunel_admin() {
    ssh_ip "$CLI" "echo '$GUEST_PASS' | sudo -S -p '' systemctl start openvpn-client@the-store" </dev/null >/dev/null 2>&1 || true
    TUNEL_APAGADO=0
}
trap 'if (( TUNEL_APAGADO )); then levanta_tunel_admin; fi; on_exit' EXIT

cu1() {
    local ok0=$OK fallos0=$FALLOS
    banner "CU1: DENEGACIÓN POR DEFECTO EN LA WAN Y ENDURECIMIENTO DEL GATEWAY (cli-adm sin túnel)"

    paso "cli-adm es un equipo de la WAN: se apaga su túnel para verlo como lo vería un atacante"
    TUNEL_APAGADO=1
    probe_root cli-adm "systemctl stop openvpn-client@the-store; sleep 1; ip -4 -br addr; echo ---; ip route" \
        "systemctl stop openvpn-client@the-store; ip -4 -br addr; ip route"
    detail_no "cli-adm no tiene interfaz de túnel" 'tun0'
    pausa

    paso "Escaneo TCP de gw-vpn (203.0.113.10) a los puertos que importan: SSH, DNS, HTTP, HTTPS, OpenVPN sobre TCP y API de Kubernetes"
    corre chk_wan_tcp_filtered
    nota "gw-vpn registra en el log del kernel los paquetes descartados, entre ellos los del SSH (puerto 22)"
    corre chk_drop_logged input "$CLI" 203.0.113.10 22
    pausa

    paso "Sondeo UDP al puerto 1194: nmap y un datagrama sin la clave tls-crypt"
    probe_root cli-adm "nmap -Pn -sU -p 1194 --max-retries 1 --host-timeout 15s 203.0.113.10"
    nota "open|filtered significa que no hubo respuesta: no prueba que el puerto esté cerrado ni identifica a OpenVPN"
    corre chk_wan_udp_silent
    pausa

    paso "Intento de llegar a la red interna sin ruta: Ingress (80), SSH (22) y API de Kubernetes (6443) de 10.10.10.5"
    corre chk_lan_blocked_no_route 10.10.10.5
    pausa

    paso "Se agrega a mano una ruta hacia la LAN a través del gateway y se repite"
    nota "nftables en el FORWARD de gw-vpn descarta los paquetes y los registra"
    corre chk_lan_blocked_with_route 10.10.10.5
    pausa

    paso "Qué escucha gw-vpn y con qué usuario corre OpenVPN"
    corre chk_gw_hardening
    pausa

    paso "Política del firewall de gw-vpn (nftables)"
    probe_root gw-vpn "nft list ruleset | head -n 70"
    detail "La cadena input descarta por defecto" 'hook input priority filter; policy drop'
    detail "La cadena forward descarta por defecto" 'hook forward priority filter; policy drop'
    pausa

    paso "Se vuelve a levantar el túnel de cli-adm (admin-01, 10.8.0.20)"
    probe_root cli-adm 'systemctl start openvpn-client@the-store; for i in $(seq 30); do ip -4 -br addr show tun0 2>/dev/null | grep -q 10.8.0.20 && break; sleep 1; done; ip -4 -br addr show tun0' \
        "systemctl start openvpn-client@the-store; ip -4 -br addr show tun0"
    TUNEL_APAGADO=0
    fin_caso CU1 "$ok0" "$fallos0"
}

cu2() {
    local ok0=$OK fallos0=$FALLOS
    banner "CU2: ALTA DEL DESARROLLADOR, CONEXIÓN POR VPN Y USO DE LA APLICACIÓN (cliente Windows, $DEV_CLIENT)"

    paso "Alta en la CA: certificado público, emisor, vigencia y CCD del usuario (la clave privada no se muestra)"
    corre chk_dev_enrollment "$DEV_CLIENT" "$DEV_IP"
    pausa

    paso "Perfil .ovpn unificado: directivas y bloques (ca, cert, key, tls-crypt) sin imprimir las claves"
    probe_dev "grep -E '^(client|dev|proto|remote|remote-cert-tls|tls-version-min|pull-filter|explicit-exit-notify)( |\$)|^</?(ca|cert|key|tls-crypt)>' \"$PROFILES_DIR/$DEV_CLIENT.ovpn\""
    detail "El perfil incluye tls-crypt" '<tls-crypt>'
    pausa

    paso "Se conecta '$DEV_CLIENT' con OpenVPN GUI (si no estaba conectado)"
    requiere_tunel || return 0

    paso "Del lado del cliente: IP del túnel y rutas (solo hacia 10.10.10.5)"
    probe_dev "powershell.exe -NoProfile -Command \"Get-NetIPAddress -IPAddress $DEV_IP | Format-List InterfaceAlias,IPAddress,PrefixLength\""
    detail "Windows tiene la IP fija del perfil ($DEV_IP) en el adaptador del túnel" "IPAddress +: +$DEV_IP_RE"
    probe_dev "route print -4 | grep -E '10\.10\.10\.5|10\.8\.0\.1 '"
    detail "Solo 10.10.10.5 se enruta por el túnel (split-tunnel)" '10\.10\.10\.5 +255\.255\.255\.255 +10\.8\.0\.1'
    pausa

    paso "DNS del cliente: la política NRPT manda solo la zona de la tienda al DNS del gateway"
    probe_dev "powershell.exe -NoProfile -Command \"Get-DnsClientNrptPolicy -Effective | Format-List Namespace,NameServers\""
    detail "Solo la zona .the-store.internal se manda al DNS 10.8.0.1" 'Namespace +: +\.the-store\.internal'
    pausa

    paso "Del lado del servidor: gw-vpn ve al cliente con su IP fija"
    probe_sessions
    detail "gw-vpn tiene a $DEV_CLIENT conectado con $DEV_IP" "^$DEV_CLIENT,.*,$DEV_IP_RE\$"
    nota "Log de gw-vpn: verificación del certificado, IP fija del CCD y cifrado negociado"
    probe_root gw-vpn "journalctl -u openvpn-server@the-store -b --no-pager | grep -E \"VERIFY OK.*CN=$DEV_CLIENT|$DEV_CLIENT/.*MULTI: primary virtual IP\" | tail -n 3 | cut -c1-170"
    detail "El servidor verificó el certificado de $DEV_CLIENT" "VERIFY OK: depth=0, CN=$DEV_CLIENT"
    pausa

    paso "DNS interno: resuelve la zona de la tienda y rechaza dominios externos"
    probe_dev "nslookup ui.the-store.internal 10.8.0.1 | tail -n 3"
    detail "ui.the-store.internal resuelve a 10.10.10.5" 'Address: +10\.10\.10\.5'
    probe_dev "nslookup example.com 10.8.0.1"
    detail "El DNS interno rechaza dominios externos" 'refused|rechaz'
    pausa

    paso "La aplicación, a través del túnel y por nombre: catálogo, UI y una compra por la API (se agrega un ítem al carrito y se vuelve a leer)"
    corre chk_dev_app "demo-$DEV_CLIENT"
    pausa

    paso "Flujo de compra en el navegador: catálogo, producto, carrito, dirección, envío, pago de ejemplo y confirmación"
    nota "Abrir http://ui.the-store.internal/ en el navegador y recorrer la compra con datos ficticios"
    if [[ "${DEMO_AUTO:-0}" != 1 ]]; then
        powershell.exe -NoProfile -Command "Start-Process http://ui.the-store.internal/" >/dev/null 2>&1 || true
        pausa
    fi
    fin_caso CU2 "$ok0" "$fallos0"
}

cu3() {
    local ok0=$OK fallos0=$FALLOS
    banner "CU3: AUTORIZACIÓN POR ROL (mismo destino, permisos distintos)"

    paso "Qué decide el rol: IP fija y ruta por CCD, y reglas nftables por rango de IP del túnel"
    corre chk_role_rules "$DEV_CLIENT"
    pausa

    if requiere_tunel; then
        paso "Desarrollador ($DEV_CLIENT): el Ingress (80) responde y SSH (22) y la API de Kubernetes (6443) no"
        corre chk_dev_ports
        nota "gw-vpn audita cada intento bloqueado"
        corre chk_drop_logged forward "$DEV_IP" 10.10.10.5 '22|6443'
        pausa

        paso "Desarrollador: los cinco microservicios responden por el Ingress (health checks)"
        probe_dev "for s in $SERVICIOS; do printf '%-9s HTTP ' \"\${s%%:*}\"; curl -s --noproxy '*' --max-time 8 -o /dev/null -w '%{http_code}\n' \"http://\${s%%:*}.the-store.internal/\${s#*:}\"; done"
        detail_n "Los cinco servicios responden HTTP 200" 5 'HTTP 200$'
        pausa

        paso "Desarrollador: sin acceso al gateway (SSH y gestión)"
        corre chk_dev_gateway_blocked
        pausa
    fi

    paso "Sysadmin (cli-adm, admin-01): mismo destino 10.10.10.5, puertos 80, 22 y 6443 abiertos"
    probe_user cli-adm "ip -4 -br addr show tun0; $(ports_cmd 10.10.10.5 '80 22 6443')"
    detail_n "80, 22 y 6443 están abiertos para el sysadmin" 3 'ABIERTO'
    pausa

    paso "Sysadmin: administra el nodo por SSH"
    corre chk_sysadmin_ssh_node
    pausa

    paso "Sysadmin: con el token acotado del kubeconfig lista pods y lee logs"
    corre chk_sysadmin_k8s_read
    pausa

    paso "Sysadmin: mínimo privilegio (RBAC) en Kubernetes"
    corre chk_sysadmin_rbac
    pausa

    paso "Sysadmin: no llega a la administración del gateway ni de la CA"
    corre chk_sysadmin_isolated
    pausa
    fin_caso CU3 "$ok0" "$fallos0"
}

cu4() {
    local ok0=$OK fallos0=$FALLOS
    banner "CU4: REVOCACIÓN EN CALIENTE DE '$DEV_CLIENT' DESDE LA CA"
    requiere_tunel || return 0

    if [[ "${DEMO_AUTO:-0}" != 1 ]]; then
        read -r -p "Esto revoca el certificado de $DEV_CLIENT (se restaura con 'setup-lab.sh reset-demo'). ¿Seguir? [s/N] " r
        [[ "$r" == [sS] ]] || return 0
    fi
    sync_clocks

    paso "Antes: tres clientes conectados y el sysadmin operando"
    corre chk_clients_connected "Están conectados $DEV_CLIENT, admin-01 y gw-sucursal" "$DEV_CLIENT" admin-01 gw-sucursal
    probe_user cli-adm "date -u +%T; kubectl get pods -n the-store --no-headers | head -n 2"
    detail "El sysadmin lista pods" 'Running'
    pausa

    paso "En la CA: revocar el certificado (la CRL cambia solo en la CA)"
    corre chk_revoke "$DEV_CLIENT"
    nota "La CRL todavía no llegó a gw-vpn: la sesión sigue en pie"
    probe_sessions
    detail "$DEV_CLIENT sigue conectado hasta que se publique la CRL" "^$DEV_CLIENT,"
    pausa

    paso "Publicar la CRL en gw-vpn: se instala y se corta la sesión del revocado"
    corre chk_publish_crl "$DEV_CLIENT"
    pausa

    paso "Después: $DEV_CLIENT desaparece, los demás siguen conectados y operando"
    corre chk_revoked_gone "$DEV_CLIENT" admin-01 gw-sucursal
    probe_user cli-adm "date -u +%T; kubectl get pods -n the-store --no-headers | head -n 2"
    detail "La sesión del sysadmin siguió funcionando" 'Running'
    probe_dev "curl -s --noproxy '*' --max-time 5 -o /dev/null -w 'Windows -> ui.the-store.internal: HTTP %{http_code}\n' http://ui.the-store.internal/home; true"
    detail "Windows ya no llega a la tienda (HTTP 000: sin conexión)" 'HTTP 000'
    pausa

    paso "El certificado revocado intenta reconectar: gw-vpn lo rechaza por la CRL"
    nota "OpenVPN GUI reintenta solo; además se prueba el mismo perfil desde cli-adm (si la revocación fallara, conectaría)"
    corre chk_revoked_rejected "$DEV_CLIENT"
    nota "La revocación corta el acceso por la VPN: no invalida el token de Kubernetes ni la clave SSH del usuario"
    nota "Para dejar el laboratorio limpio: bash setup-lab.sh reset-demo"
    pausa
    fin_caso CU4 "$ok0" "$fallos0"
}

cu5() {
    local ok0=$OK fallos0=$FALLOS interno
    banner "CU5: CONFIDENCIALIDAD, TÚNEL DIVIDIDO Y DNS INTERNO"
    requiere_tunel || return 0
    interno="demo$RANDOM.the-store.internal"

    paso "Captura simultánea en gw-vpn (WAN, LAN y túnel) mientras Windows usa la tienda y resuelve nombres"
    nota "WAN (eth0, UDP/1194): lo que vería un atacante. LAN (eth1, TCP/80): detrás del gateway. tun0 (UDP/53): consultas DNS que entran por la VPN."
    cap_start 12 "eth0|udp port 1194|/tmp/demo-wan.cap" "eth1|tcp port 80|/tmp/demo-lan.cap" "tun0|udp port 53|/tmp/demo-dns.cap"
    sleep 4
    probe_dev "for i in 1 2 3; do curl -s --noproxy '*' -o /dev/null http://ui.the-store.internal/; done"
    probe_dev "powershell.exe -NoProfile -Command \"Resolve-DnsName $interno -Type A -DnsOnly -ErrorAction SilentlyContinue; Resolve-DnsName orders.the-store.internal -Type A -DnsOnly | Format-Table Name,Type,IPAddress -AutoSize; Resolve-DnsName google.com -Type A -DnsOnly | Format-Table Name,Type,IPAddress -AutoSize\""
    detail "El nombre interno se resuelve a 10.10.10.5" 'orders\.the-store\.internal +A +10\.10\.10\.5'
    wait
    pausa

    paso "WAN: datagramas UDP cifrados, sin nombres ni HTTP legibles"
    nota "203.0.113.50 = este Windows, .20 = gw-sucursal, .51 = cli-adm, .10 = gw-vpn (UDP/1194)"
    corre chk_wan_encrypted /tmp/demo-wan.cap 203.0.113.50
    pausa

    paso "LAN: el mismo tráfico, ya descifrado por el gateway"
    corre chk_lan_clear /tmp/demo-lan.cap
    nota "El origen en eth1 es 10.10.0.1: gw-vpn hace SNAT hacia la LAN. El cifrado llega hasta el gateway; el HTTP interno va en claro."
    pausa

    paso "Túnel dividido: la ruta por defecto de Windows no pasa por la VPN, solo 10.10.10.5/32"
    probe_dev "route print -4 | grep -E '^ +0\.0\.0\.0 +0\.0\.0\.0'"
    detail_no "La ruta por defecto no apunta al gateway de la VPN (10.8.0.1)" '10\.8\.0\.1 '
    probe_dev "route print -4 | grep -E '10\.10\.10\.5 +255'"
    pausa

    paso "DNS dividido: por el túnel solo entran consultas de la zona interna"
    nota "Consultas DNS que gw-vpn recibió por tun0 durante la captura (nombre interno aleatorio para evitar la caché de Windows)"
    probe_root gw-vpn "grep -aoE '(A|AAAA)\? [^ ]+' /tmp/demo-dns.cap | sort | uniq -c"
    detail "La consulta del nombre interno entró por el túnel" "\? $interno"
    detail_no "google.com no pasó por el túnel: Windows lo resolvió con su DNS local" 'google\.com'
    cap_rm /tmp/demo-wan.cap /tmp/demo-lan.cap /tmp/demo-dns.cap
    pausa
    fin_caso CU5 "$ok0" "$fallos0"
}

cu6() {
    local ok0=$OK fallos0=$FALLOS
    banner "CU6: SUCURSAL SITE-TO-SITE (host-suc -> gw-sucursal -> túnel -> gw-vpn)"

    paso "gw-sucursal mantiene su túnel permanente con gw-vpn"
    corre chk_branch_tunnel
    pausa

    paso "gw-sucursal reenvía sin NAT y solo deja pasar el Ingress"
    probe_vbox gw-sucursal "echo \"reglas NAT en gw-sucursal: \$(echo '$GUEST_PASS' | sudo -S -p '' nft list ruleset | grep -cE 'snat|masquerade')\"; ip -4 -br addr; echo '--- nft: cadena forward'; echo '$GUEST_PASS' | sudo -S -p '' nft list chain inet filter forward" \
        "nft list ruleset | grep -cE 'snat|masquerade'; ip -4 -br addr; nft list chain inet filter forward"
    detail "gw-sucursal no hace NAT" 'reglas NAT en gw-sucursal: 0'
    detail "Solo reenvía 172.16.20.0/24 hacia 10.10.10.5:80" 'saddr 172\.16\.20\.0/24 ip daddr 10\.10\.10\.5 tcp dport 80 accept'
    pausa

    paso "host-suc (172.16.20.10) sin cliente VPN: usa a gw-sucursal como puerta de enlace y DNS, llega a los cinco servicios y no al SSH ni a la API"
    corre chk_branch_host
    pausa

    paso "Capturas en gw-vpn: entre los gateways solo UDP cifrado; dentro del túnel se conserva el origen de la sucursal"
    nota "eth0 (WAN, UDP/1194 con gw-sucursal) y tun0 (ya descifrado, antes del SNAT hacia la LAN)"
    cap_start 10 "eth0|udp port 1194 and host 203.0.113.20|/tmp/demo-suc-wan.cap" "tun0|tcp port 80 and host 172.16.20.10|/tmp/demo-suc-tun.cap"
    sleep 3
    probe_vbox host-suc "for i in 1 2 3; do curl -s -o /dev/null http://ui.the-store.internal/home; done"
    wait
    corre chk_wan_encrypted /tmp/demo-suc-wan.cap 203.0.113.20
    probe_root gw-vpn "grep -aE ' IP 172\.16\.20\.10\.[0-9]+ > 10\.10\.10\.5\.80|Host:' /tmp/demo-suc-tun.cap | head -n 4 | cut -c1-120" \
        "grep -E '172.16.20.10.* > 10.10.10.5.80|Host:' captura-tun0"
    detail "En tun0 se ve el origen real de la sucursal (172.16.20.10), sin NAT en gw-sucursal" '172\.16\.20\.10\.[0-9]+ > 10\.10\.10\.5\.80'
    cap_rm /tmp/demo-suc-wan.cap /tmp/demo-suc-tun.cap
    pausa
    fin_caso CU6 "$ok0" "$fallos0"
}

menu() {
    local opcion
    while true; do
        printf "\n${C_BOLD}Demostración${C_RESET}\n  1) CU1  Denegación por defecto en la WAN\n  2) CU2  Alta y conexión del desarrollador\n  3) CU3  Acceso por rol\n  4) CU4  Revocación\n  5) CU5  Cifrado, túnel dividido y DNS\n  6) CU6  Sucursal\n  7) Todo\n  q) Salir\n"
        read -r -p "Elegí: " opcion || return 0
        case "$opcion" in
            1) cu1 ;;
            2) cu2 ;;
            3) cu3 ;;
            4) cu4 ;;
            5) cu5 ;;
            6) cu6 ;;
            7) cu1; cu2; cu3; cu5; cu6; cu4 ;;
            q|Q) return 0 ;;
        esac
    done
}

resumen() {
    local color=$C_GREEN
    (( FALLOS == 0 )) || color=$C_RED
    printf "\n${color}${C_BOLD}Verificaciones: %d correctas, %d fallidas${C_RESET}\n" "$OK" "$FALLOS"
    (( FALLOS == 0 ))
}

ssh_ip "$GW" true </dev/null 2>/dev/null || { echo "El laboratorio no está encendido: bash setup-lab.sh start" >&2; exit 1; }

case "${1:-}" in
    cu1|cu2|cu3|cu4|cu5|cu6) "$1"; resumen ;;
    todo) cu1; cu2; cu3; cu5; cu6; cu4; resumen ;;
    "") menu ;;
    *) echo "Uso: $0 [cu1|cu2|cu3|cu4|cu5|cu6|todo]" >&2; exit 1 ;;
esac
