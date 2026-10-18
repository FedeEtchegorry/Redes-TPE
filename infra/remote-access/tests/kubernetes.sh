#!/usr/bin/env bash
# Tests the cluster on k8s-node, after ./local.sh create-cluster --remote-access.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NODE_IP=10.10.10.5
FAILED=0

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
    local path=/actuator/health/readiness
    if [[ $1 == catalog || $1 == checkout ]]; then
        path=/health
    fi
    curl --noproxy '*' --silent --show-error --fail --max-time 10 --output /dev/null \
        --resolve "$1.the-store.internal:80:$NODE_IP" "http://$1.the-store.internal$path"
}

sysadmin_can() {
    kubectl auth can-i --as system:serviceaccount:the-store:sysadmin "$@"
}

sysadmin_cannot() {
    [[ $(sysadmin_can "$@") == no ]]
}

kubeconfig_lists_pods() {
    local file status
    file=$(mktemp -u)
    bash "$ROOT/scripts/sysadmin-kubeconfig.sh" "$file" 10m &&
        KUBECONFIG=$file kubectl get pods --namespace the-store
    status=$?
    rm -f "$file"
    return "$status"
}

run "API server answers on https://$NODE_IP:6443" kubectl --server "https://$NODE_IP:6443" get --raw /readyz
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
