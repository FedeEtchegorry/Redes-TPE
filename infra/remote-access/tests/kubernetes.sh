#!/usr/bin/env bash
# Tests the cluster on k8s-node, after ./local.sh create-cluster --remote-access.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NODE_IP=10.10.10.5
INGRESS_WAIT=${INGRESS_WAIT:-60}
FAILED=0

# Prerequisite check: skip gracefully if the cluster API server is not running
if ! timeout 2 bash -c "true < /dev/tcp/$NODE_IP/6443" 2>/dev/null && \
   ! timeout 2 curl -kfsS --connect-timeout 2 "https://$NODE_IP:6443/livez" >/dev/null 2>&1; then
    if [[ "${REQUIRE_CLUSTER:-0}" == "1" ]]; then
        echo "FAIL  Prerequisite: Cluster API server is reachable on https://$NODE_IP:6443"
        echo "      Cluster is not reachable at https://$NODE_IP:6443."
        echo "      Ensure 10.10.10.5 is assigned (e.g. 'sudo ip addr add 10.10.10.5/32 dev lo')"
        echo "      and the cluster is created with: ./local.sh create-cluster --remote-access"
        exit 1
    else
        echo "SKIP  Cluster is not reachable at https://$NODE_IP:6443 (start with: ./local.sh create-cluster --remote-access)"
        exit 0
    fi
fi

run() {
    local description=$1 output line
    shift
    if output=$("$@" 2>&1); then
        echo "ok    $description"
    else
        echo "FAIL  $description"
        while IFS= read -r line; do echo "      $line"; done <<< "$output"
        FAILED=1
    fi
}

service_responds() {
    local path=/actuator/health/readiness options
    if [[ $1 == catalog || $1 == checkout ]]; then
        path=/health
    fi
    options=(--noproxy '*' --silent --show-error --connect-timeout 2 --max-time 10
        --resolve "$1.the-store.internal:80:$NODE_IP" "http://$1.the-store.internal$path")
    curl "${options[@]}" --fail --retry "$((INGRESS_WAIT / 3))" --retry-delay 3 --output /dev/null || {
        curl "${options[@]}"
        return 1
    }
}

sysadmin_can() {
    kubectl --request-timeout=10s auth can-i --as system:serviceaccount:the-store:sysadmin "$@"
}

sysadmin_cannot() {
    [[ $(sysadmin_can "$@") == no ]]
}

kubeconfig_lists_pods() {
    local file status
    file=$(mktemp -u)
    bash "$ROOT/scripts/sysadmin-kubeconfig.sh" "$file" 10m &&
        KUBECONFIG=$file kubectl --request-timeout=10s get pods --namespace the-store
    status=$?
    rm -f "$file"
    return "$status"
}

run "API server answers on https://$NODE_IP:6443" kubectl --request-timeout=10s --server "https://$NODE_IP:6443" get --raw /readyz
for service in ui catalog carts orders checkout; do
    run "$service.the-store.internal answers through the Ingress on $NODE_IP:80" service_responds "$service"
done
run "sysadmin lists pods in the-store" sysadmin_can list pods --namespace the-store
run "sysadmin reads logs in the-store" sysadmin_can get pods --subresource log --namespace the-store
run "sysadmin cannot read Secrets" sysadmin_cannot get secrets --namespace the-store
run "sysadmin cannot exec into pods" sysadmin_cannot create pods --subresource exec --namespace the-store
run "sysadmin cannot delete pods" sysadmin_cannot delete pods --namespace the-store
run "sysadmin cannot list pods in kube-system" sysadmin_cannot list pods --namespace kube-system
run "sysadmin kubeconfig lists pods with TLS verification" kubeconfig_lists_pods
exit "$FAILED"
