#!/usr/bin/env bash
# Shared by setup-lab.sh and eval.sh. The caller sets LOG_NAME before sourcing it.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REMOTE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

GUEST_USER=${GUEST_USER:-home}
GUEST_PASS=${GUEST_PASS:-bishbashbosh}
CA_PASS=${CA_PASS:-$GUEST_PASS}
PROFILES_DIR="$REMOTE_DIR/profiles"
HOST_KEY="$PROFILES_DIR/host_admin_ed25519"
NO_PAUSE=${NO_PAUSE:-0}
ALL_VMS=(gw-vpn k8s-node ca cli-adm gw-sucursal host-suc)

if command -v VBoxManage >/dev/null 2>&1; then
    VBOX="VBoxManage"
elif [[ -x "/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" ]]; then
    VBOX="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
    export PATH="/c/Program Files/Oracle/VirtualBox:$PATH"
else
    echo "ERROR: No se encontró VBoxManage. Instalá VirtualBox 7 primero." >&2
    exit 1
fi

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

mkdir -p "$PROFILES_DIR"
LOG_FILE="$PROFILES_DIR/$LOG_NAME.log"
: > "$LOG_FILE"

log_out() {
    printf "%b" "$*"
    printf "%b" "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

banner() {
    log_out "\n${C_BLUE}==============================================================================${C_RESET}\n"
    log_out "${C_BOLD}${C_CYAN}  $*${C_RESET}\n"
    log_out "${C_BLUE}==============================================================================${C_RESET}\n"
}

SSH_OPTS=(-i "$HOST_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
ssh_ip() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" "$@"; }

on_exit() {
    local code=$?
    printf "\n${C_CYAN}[LOG]${C_RESET} Resumen guardado en: %s\n" "$LOG_FILE"
    if [[ -t 0 && "$NO_PAUSE" == "0" ]]; then
        printf "\n${C_BOLD}${C_YELLOW}Ejecución finalizada (código %d). Presioná ENTER para cerrar...${C_RESET}" "$code"
        read -r _ || true
    fi
}
trap on_exit EXIT

GW=192.168.100.1
CA=192.168.100.20
CLI=203.0.113.51
CA_DIR=/root/ca-store
PKI_SH=/home/$GUEST_USER/Redes-TPE/infra/remote-access/scripts/pki.sh
DEMO_ITEM=a1258cd2-176c-4507-ade6-746dab5ad625
SERVICIOS="ui:actuator/health/readiness carts:actuator/health/readiness orders:actuator/health/readiness catalog:health checkout:health"
DROP_SED='s/.*(the-store (input|forward) drop).*(SRC=[0-9.]+ DST=[0-9.]+).*(PROTO=[A-Z]+ SPT=[0-9]+ DPT=[0-9]+).*/\1 \3 \4/'

CHK_OUT=""
CHK_TRACE=""
DETAIL_FAILS=0
DEV_LABEL="dev"

on_cmd() { :; }
on_out() { :; }
on_detail() { :; }

dev_run() { echo "dev_run no está definido" >&2; return 1; }

vm_ip() {
    case "$1" in
        gw-vpn) echo "$GW" ;;
        ca) echo "$CA" ;;
        cli-adm) echo "$CLI" ;;
        *) echo "$1" ;;
    esac
}

_probe_end() {
    CHK_TRACE+="[$1] \$ $2"$'\n'"$CHK_OUT"$'\n'
    on_out
}

probe_root() { # VM COMANDO [TEXTO]: como root por SSH
    on_cmd "$1" "${3:-$2}"
    CHK_OUT=$(ssh_ip "$(vm_ip "$1")" "echo '$GUEST_PASS' | sudo -S -p '' bash -c $(printf %q "$2")" 2>&1 </dev/null | tr -d '\r' || true)
    _probe_end "$1" "${3:-$2}"
}

probe_user() { # VM COMANDO [TEXTO]: como el usuario del laboratorio por SSH
    on_cmd "$1" "${3:-$2}"
    CHK_OUT=$(ssh_ip "$(vm_ip "$1")" "$2" 2>&1 </dev/null | tr -d '\r' || true)
    _probe_end "$1" "${3:-$2}"
}

probe_vbox() { # VM COMANDO [TEXTO]: VMs sin red hacia el host (host-suc, gw-sucursal), por guestcontrol
    on_cmd "$1" "${3:-$2}"
    CHK_OUT=$(MSYS2_ARG_CONV_EXCL="*" "$VBOX" guestcontrol "$1" run --exe /bin/bash --username "$GUEST_USER" \
        --password "$GUEST_PASS" -- -c "$2" 2>&1 </dev/null | tr -d '\r' || true)
    _probe_end "$1" "${3:-$2}"
}

probe_dev() { # COMANDO [TEXTO]: en el cliente dev
    on_cmd "$DEV_LABEL" "${2:-$1}"
    CHK_OUT=$(dev_run "$1" 2>&1 | tr -d '\r' || true)
    _probe_end "$DEV_LABEL" "${2:-$1}"
}

probe_sessions() {
    probe_root gw-vpn "(printf 'status 2\n'; sleep 0.3; printf 'quit\n') | socat - UNIX-CONNECT:/run/openvpn-server/the-store.sock | tr -d '\r' | grep '^CLIENT_LIST' | cut -d, -f2-4" \
        "echo 'status 2' | socat - UNIX-CONNECT:/run/openvpn-server/the-store.sock   # clientes: nombre, dirección real, IP del túnel"
}

ports_cmd() { # HOST "PUERTO..."
    printf 'for p in %s; do timeout 3 bash -c "true </dev/tcp/%s/$p" 2>/dev/null && echo "%s:$p ABIERTO" || echo "%s:$p bloqueado"; done' "$2" "$1" "$1" "$1"
}

_detail() { # DESCRIPCIÓN ESTADO [DETALLE]
    (( $2 == 0 )) || DETAIL_FAILS=$((DETAIL_FAILS + 1))
    on_detail "$1" "$2" "${3:-}"
}

detail() { # DESCRIPCIÓN REGEX: CHK_OUT debe tener REGEX
    if grep -qaiE -- "$2" <<<"$CHK_OUT"; then _detail "$1" 0; else _detail "$1" 1; fi
}

detail_no() { # DESCRIPCIÓN REGEX: CHK_OUT no debe tener REGEX
    if grep -qaiE -- "$2" <<<"$CHK_OUT"; then _detail "$1" 1; else _detail "$1" 0; fi
}

detail_n() { # DESCRIPCIÓN N REGEX: exactamente N líneas con REGEX
    local n
    n=$(grep -caiE -- "$3" <<<"$CHK_OUT" || true)
    if (( n == $2 )); then _detail "$1" 0; else _detail "$1" 1 "$n de $2"; fi
}

chk_ok() { (( DETAIL_FAILS == $1 )); } # FALLOS_AL_EMPEZAR: 0 si el chequeo no sumó fallos

chk_wan_tcp_filtered() {
    local f0=$DETAIL_FAILS
    probe_root cli-adm "nmap -Pn -sS -p 22,53,80,443,1194,6443 --max-retries 1 --host-timeout 30s 203.0.113.10"
    detail_n "Los seis puertos están filtrados: no hay respuesta ni RST" 6 '/tcp +filtered '
    chk_ok "$f0"
}

chk_drop_logged() { # TIPO(input|forward) ORIGEN DESTINO "PUERTO|PUERTO"
    local f0=$DETAIL_FAILS
    probe_root gw-vpn "dmesg | grep 'the-store $1 drop' | grep 'SRC=$2 ' | grep -E 'DST=$3 .*DPT=($4)( |\$)' | tail -n 3 | sed -E '$DROP_SED'"
    detail "gw-vpn registró el descarte ($1) de $2 hacia $3" "$1 drop SRC=${2//./\\.} DST=${3//./\\.} .*DPT=($4)"
    chk_ok "$f0"
}

chk_wan_udp_silent() {
    local f0=$DETAIL_FAILS
    probe_root cli-adm "echo -n PROBE_SIN_TLS_CRYPT | socat -T 1 - UDP4:203.0.113.10:1194 | wc -c" \
        "echo -n PROBE | socat -T 1 - UDP4:203.0.113.10:1194 | wc -c   # bytes recibidos"
    detail "OpenVPN no contesta sin tls-crypt (0 bytes)" '^[[:space:]]*0[[:space:]]*$'
    chk_ok "$f0"
}

chk_lan_blocked_no_route() { # DESTINO
    local f0=$DETAIL_FAILS
    probe_root cli-adm "$(ports_cmd "$1" '80 22 6443')"
    detail_n "Ningún puerto de $1 es alcanzable sin ruta" 3 ' bloqueado$'
    chk_ok "$f0"
}

chk_lan_blocked_with_route() { # DESTINO: con una ruta manual hacia la LAN por el gateway
    local f0=$DETAIL_FAILS
    probe_root cli-adm "ip route add 10.10.0.0/16 via 203.0.113.10; ip route get $1 | head -n 1; $(ports_cmd "$1" '80 22 6443'); ip route del 10.10.0.0/16 via 203.0.113.10" \
        "ip route add 10.10.0.0/16 via 203.0.113.10; (intentos a $1:80, :22 y :6443); ip route del 10.10.0.0/16"
    detail "La ruta manual apunta al gateway" "${1//./\\.} via 203\.0\.113\.10"
    detail_n "Ni siquiera con la ruta manual se alcanza la LAN" 3 ' bloqueado$'
    chk_drop_logged forward "$CLI" "$1" '80|22|6443' || true
    chk_ok "$f0"
}

chk_gw_hardening() {
    local f0=$DETAIL_FAILS
    probe_root gw-vpn "ss -tulnp | grep -E 'openvpn|sshd|dnsmasq'; ps -C openvpn -o user=,cmd= | head -n 1"
    detail "OpenVPN escucha solo en la IP de la WAN, UDP/1194" '203\.0\.113\.10:1194.*openvpn'
    detail "sshd escucha en la red de gestión (192.168.100.1:22)" '192\.168\.100\.1:22.*sshd'
    detail_no "sshd no escucha en otras interfaces" '(0\.0\.0\.0|\*|\[::\]):22 .*sshd'
    detail "OpenVPN corre sin privilegios (usuario nobody)" '^nobody '
    chk_ok "$f0"
}

chk_dev_enrollment() { # CLIENTE IP
    local f0=$DETAIL_FAILS
    probe_root ca "openssl x509 -in $CA_DIR/pki/issued/$1.crt -noout -subject -issuer -dates; echo '--- ccd/$1'; cat $CA_DIR/ccd/$1"
    detail "El certificado es de $1" "subject=CN *= *$1"
    detail "El CCD le fija la IP $2" "ifconfig-push ${2//./\\.} "
    detail "El CCD solo le da ruta a 10.10.10.5/32" 'push "route 10\.10\.10\.5 255\.255\.255\.255"'
    chk_ok "$f0"
}

chk_role_rules() { # CLIENTE_DEV
    local f0=$DETAIL_FAILS
    probe_root gw-vpn "for f in $1 admin-01; do echo \"== ccd/\$f\"; cat /etc/openvpn/server/the-store/ccd/\$f; done; echo '== nft: cadena forward'; nft list chain inet filter forward"
    detail "El firewall deja a dev (.10-.19) solo el puerto 80 del nodo" 'saddr 10\.8\.0\.10-10\.8\.0\.19 ip daddr 10\.10\.10\.5 tcp dport 80 accept'
    detail "El firewall deja al sysadmin (.20-.29) los puertos 22, 80 y 6443" 'saddr 10\.8\.0\.20-10\.8\.0\.29 ip daddr 10\.10\.10\.5 tcp dport \{ 22, 80, 6443 \} accept'
    detail "Todo lo demás se descarta y se registra" 'forward drop'
    chk_ok "$f0"
}

chk_dev_app() { # ID_DE_CARRITO
    local f0=$DETAIL_FAILS
    probe_dev "curl -s --noproxy '*' --max-time 10 http://catalog.the-store.internal/catalog/products | head -c 300; echo"
    detail "El catálogo devuelve productos" "$DEMO_ITEM"
    probe_dev "curl -s --noproxy '*' --max-time 10 http://ui.the-store.internal/home | grep -i '<title>'"
    detail "La UI devuelve su página" '<title>'
    probe_dev "curl -s --noproxy '*' --max-time 10 -X POST -H 'Content-Type: application/json' -d '{\"itemId\":\"$DEMO_ITEM\",\"unitPrice\":199,\"quantity\":2}' -w '\nHTTP %{http_code}\n' http://carts.the-store.internal/carts/$1/items"
    detail "El carrito acepta el ítem" 'HTTP 20[01]'
    probe_dev "curl -s --noproxy '*' --max-time 10 http://carts.the-store.internal/carts/$1/items"
    detail "El carrito devuelve el ítem agregado" "$DEMO_ITEM"
    chk_ok "$f0"
}

chk_dev_ports() {
    local f0=$DETAIL_FAILS
    probe_dev "$(ports_cmd 10.10.10.5 '80 22 6443')"
    detail "10.10.10.5:80 (Ingress) está abierto para el rol dev" '10\.10\.10\.5:80 ABIERTO'
    detail "10.10.10.5:22 (SSH) está bloqueado para el rol dev" '10\.10\.10\.5:22 bloqueado'
    detail "10.10.10.5:6443 (API de Kubernetes) está bloqueado para el rol dev" '10\.10\.10\.5:6443 bloqueado'
    chk_ok "$f0"
}

chk_dev_gateway_blocked() {
    local f0=$DETAIL_FAILS
    probe_dev "$(ports_cmd 10.8.0.1 22)"
    detail "El SSH del gateway (10.8.0.1:22) está bloqueado para el rol dev" '10\.8\.0\.1:22 bloqueado'
    chk_ok "$f0"
}

# cap_start SEGUNDOS "INTERFAZ|FILTRO|ARCHIVO"...: tcpdump en gw-vpn, en segundo plano; esperar con wait.
cap_start() {
    local segundos=$1 cmd="" interfaz filtro archivo spec
    shift
    for spec in "$@"; do
        IFS='|' read -r interfaz filtro archivo <<<"$spec"
        cmd+="timeout $segundos tcpdump -ni $interfaz -A -l $filtro >$archivo 2>/dev/null & "
    done
    ssh_ip "$GW" "echo '$GUEST_PASS' | sudo -S -p '' bash -c $(printf %q "$cmd wait")" </dev/null >/dev/null 2>&1 &
}

cap_rm() { # ARCHIVO...
    ssh_ip "$GW" "echo '$GUEST_PASS' | sudo -S -p '' rm -f $*" </dev/null >/dev/null 2>&1 || true
}

chk_wan_encrypted() { # ARCHIVO ORIGEN_DEL_CLIENTE
    local f0=$DETAIL_FAILS
    probe_root gw-vpn "echo \"udp=\$(grep -c 'UDP, length' $1) nombres=\$(grep -ac 'the-store.internal' $1)\"; grep -a -A2 '${2//./\\.}' $1 | head -n 12 | cut -c1-100" \
        "grep -c 'UDP, length' captura-wan; grep -c 'the-store.internal' captura-wan; grep -A2 $2 captura-wan   # paquetes UDP / nombres legibles / muestra del cliente"
    detail "La WAN solo muestra UDP cifrado, sin ningún nombre legible" 'udp=[1-9][0-9]* nombres=0'
    chk_ok "$f0"
}

chk_lan_clear() { # ARCHIVO
    local f0=$DETAIL_FAILS
    probe_root gw-vpn "grep -aE 'GET /|Host:|HTTP/1' $1 | head -n 8"
    detail "En la LAN se lee la petición HTTP en claro" 'Host: ui\.the-store\.internal'
    chk_ok "$f0"
}

chk_sysadmin_ssh_node() {
    local f0=$DETAIL_FAILS
    probe_user cli-adm "ssh -o StrictHostKeyChecking=no root@10.10.10.5 'hostname; docker ps --format \"{{.Names}}: {{.Status}}\"'"
    detail "Entra al nodo k8s-node por SSH" '^k8s-node$'
    detail "Administra el cluster Kind (docker ps)" 'the-store-control-plane'
    chk_ok "$f0"
}

chk_sysadmin_k8s_read() {
    local f0=$DETAIL_FAILS
    probe_user cli-adm "kubectl get pods -n the-store"
    detail_n "Lista los 5 pods de the-store en Running" 5 'Running'
    probe_user cli-adm "kubectl logs -n the-store deployment/catalog --tail=3 | cut -c1-160"
    detail_no "RBAC le permite leer los logs" 'Forbidden|Error from server'
    detail "Los logs no vienen vacíos" '[[:alnum:]]'
    chk_ok "$f0"
}

chk_sysadmin_rbac() {
    local f0=$DETAIL_FAILS
    probe_user cli-adm 'for c in "list pods -n the-store" "get secrets -n the-store" "delete pods -n the-store" "create pods --subresource=exec -n the-store" "list pods -n kube-system"; do printf "%-46s " "$c"; kubectl auth can-i $c; done'
    detail "Puede listar pods en the-store" '^list pods -n the-store +yes$'
    detail_n "No puede leer Secrets, borrar pods, hacer exec ni ver kube-system" 4 ' no$'
    probe_user cli-adm "kubectl get secrets -n the-store 2>&1"
    detail "Leer Secrets devuelve Forbidden" 'Forbidden'
    probe_user cli-adm "kubectl get pods -n kube-system 2>&1"
    detail "Listar pods de kube-system devuelve Forbidden" 'Forbidden'
    probe_user cli-adm "kubectl delete pod --all -n the-store --dry-run=server 2>&1"
    detail "Borrar pods devuelve Forbidden" 'Forbidden'
    detail_no "No se borró ningún pod" 'deleted'
    chk_ok "$f0"
}

chk_sysadmin_isolated() {
    local f0=$DETAIL_FAILS
    probe_user cli-adm "$(ports_cmd 10.8.0.1 22); $(ports_cmd 192.168.100.20 22)"
    detail_n "El sysadmin no alcanza ni gw-vpn ni la CA" 2 ' bloqueado$'
    chk_ok "$f0"
}

chk_branch_tunnel() {
    local f0=$DETAIL_FAILS
    probe_sessions
    detail "gw-sucursal está conectada con la IP fija 10.8.0.30" '^gw-sucursal,.*,10\.8\.0\.30$'
    probe_root gw-vpn "ip route show 172.16.20.0/24; echo '--- ccd/gw-sucursal'; cat /etc/openvpn/server/the-store/ccd/gw-sucursal"
    detail "gw-vpn enruta 172.16.20.0/24 por el túnel" '172\.16\.20\.0/24 .*dev tun0'
    detail "El CCD declara la LAN de la sucursal (iroute)" 'iroute 172\.16\.20\.0 255\.255\.255\.0'
    chk_ok "$f0"
}

chk_branch_host() {
    local f0=$DETAIL_FAILS script
    script="echo '--- identidad'; ip -4 -br addr show dev eth0; pgrep -a openvpn || echo 'sin proceso openvpn'; "
    script+="echo '--- servicios: nombre, DNS de la sucursal (172.16.20.1) y HTTP'; for s in $SERVICIOS; do n=\${s%%:*}; printf '%-9s %-12s HTTP ' \$n \"\$(dig +short @172.16.20.1 \$n.the-store.internal)\"; curl -s --max-time 10 -o /dev/null -w '%{http_code}\n' http://\$n.the-store.internal/\${s#*:}; done; "
    script+="echo '--- puertos'; $(ports_cmd 10.10.10.5 '22 6443'); $(ports_cmd 172.16.20.1 22)"
    probe_vbox host-suc "$script" "ip -4 -br addr; pgrep -a openvpn; (por servicio) dig +short @172.16.20.1 NOMBRE.the-store.internal + curl http://NOMBRE.the-store.internal/health; (puertos 10.10.10.5:22, :6443 y 172.16.20.1:22)"
    detail "No corre ningún cliente OpenVPN" 'sin proceso openvpn'
    detail_n "Los cinco servicios resuelven a 10.10.10.5 y responden HTTP 200" 5 '10\.10\.10\.5 +HTTP 200$'
    detail_n "Están bloqueados 10.10.10.5:22, 10.10.10.5:6443 y 172.16.20.1:22" 3 ' bloqueado$'
    chk_ok "$f0"
}

sync_clocks() { # OpenVPN rechaza una CRL con fecha futura: la CA y gw-vpn toman la hora del host
    local ahora ip
    ahora=$(date -u +%s)
    for ip in "$CA" "$GW"; do
        ssh_ip "$ip" "echo '$GUEST_PASS' | sudo -S -p '' date -u -s @$ahora >/dev/null" </dev/null || true
    done
}

chk_clients_connected() { # DESCRIPCIÓN CLIENTE...: exactamente esos clientes están en la lista de sesiones
    local desc=$1 f0=$DETAIL_FAILS lista
    shift
    lista=$(IFS='|'; echo "$*")
    probe_sessions
    detail_n "$desc" $# "^($lista),"
    chk_ok "$f0"
}

chk_revoke() { # CLIENTE
    local f0=$DETAIL_FAILS
    probe_root ca "export EASYRSA_PASSIN=pass:$CA_PASS
bash $PKI_SH $CA_DIR revoke $1
echo '--- certificados revocados (R) en la base de la CA'
grep '^R' $CA_DIR/pki/index.txt" \
        "pki.sh $CA_DIR revoke $1; grep '^R' $CA_DIR/pki/index.txt"
    detail "La CA registró $1 como revocado" "^R.*CN=$1"
    chk_ok "$f0"
}

chk_publish_crl() { # CLIENTE
    local f0=$DETAIL_FAILS
    sleep 2
    probe_root ca "export EASYRSA_PASSIN=pass:$CA_PASS
bash $PKI_SH $CA_DIR publish-crl $1" \
        "pki.sh $CA_DIR publish-crl $1"
    detail "La CRL quedó instalada en gw-vpn" 'CRL installed'
    detail "Se cortó la sesión activa de $1" "$1: session ended"
    chk_ok "$f0"
}

chk_revoked_gone() { # CLIENTE_REVOCADO CLIENTE_QUE_SIGUE...
    local revocado=$1 f0=$DETAIL_FAILS lista
    shift
    lista=$(IFS='|'; echo "$*")
    sleep 1
    probe_sessions
    detail_no "$revocado ya no está conectado" "^$revocado,"
    detail_n "Siguen conectados: $*" $# "^($lista),"
    chk_ok "$f0"
}

chk_revoked_rejected() { # CLIENTE: reintenta con su perfil desde cli-adm y mira el log de gw-vpn
    local f0=$DETAIL_FAILS
    ssh_ip "$CLI" "cat > /tmp/revocado.ovpn" <"$PROFILES_DIR/$1.ovpn" || true
    probe_root cli-adm "timeout 10 openvpn --config /tmp/revocado.ovpn --dev tun9 --route-noexec --ifconfig-noexec >/dev/null 2>&1; rm -f /tmp/revocado.ovpn; echo 'intento de reconexión con $1.ovpn terminado'"
    probe_root gw-vpn "journalctl -u openvpn-server@the-store --since '3 min ago' --no-pager | grep -a 'certificate revoked' | tail -n 3 | cut -c1-200"
    detail "gw-vpn rechazó la conexión: certificate revoked ($1)" "certificate revoked.*CN ?= ?$1"
    chk_ok "$f0"
}
