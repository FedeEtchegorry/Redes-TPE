#!/usr/bin/env bash
# Tests the cluster on k8s-node, after ./local.sh create-cluster --remote-access.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/run.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NODE_IP=10.10.10.5
INGRESS_WAIT=${INGRESS_WAIT:-60}

# REQUIRE_CLUSTER=1 fails instead of skipping when there is no cluster.
if ! timeout 2 bash -c "true < /dev/tcp/$NODE_IP/6443" 2> /dev/null; then
    message="Cluster is not reachable at https://$NODE_IP:6443 (needs $NODE_IP on lo and ./local.sh create-cluster --remote-access)"
    [[ ${REQUIRE_CLUSTER:-0} == 1 ]] && { echo "FAIL  $message"; exit 1; }
    echo "SKIP  $message"
    exit 0
fi

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
