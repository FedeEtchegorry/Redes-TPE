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
