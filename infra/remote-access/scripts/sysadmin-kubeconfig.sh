#!/usr/bin/env bash
set -euo pipefail
umask 077

# Writes the sysadmin kubeconfig: API server at https://10.10.10.5:6443, the cluster
# CA to verify TLS and an expiring token of the the-store/sysadmin ServiceAccount
# (k8s/sysadmin-rbac.yaml). Run on k8s-node with the Kind admin kubeconfig.
OUTPUT=${1:?Usage: sysadmin-kubeconfig.sh OUTPUT_FILE [DURATION]}
DURATION=${2:-24h}
ADDRESS=${THE_STORE_NODE_IP:-10.10.10.5}
[[ ! -e "$OUTPUT" ]] || { echo "Output file already exists" >&2; exit 1; }

CA_DATA=$(kubectl config view --raw --minify --output 'jsonpath={.clusters[0].cluster.certificate-authority-data}')
[[ -n "$CA_DATA" ]] || { echo "The current context has no embedded cluster CA" >&2; exit 1; }
TOKEN=$(kubectl -n the-store create token sysadmin --duration "$DURATION")

cat > "$OUTPUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: the-store
    cluster:
      server: https://$ADDRESS:6443
      certificate-authority-data: $CA_DATA
users:
  - name: sysadmin
    user:
      token: $TOKEN
contexts:
  - name: sysadmin
    context:
      cluster: the-store
      user: sysadmin
      namespace: the-store
current-context: sysadmin
EOF
printf 'Sysadmin kubeconfig written to %s (expires in %s)\n' "$OUTPUT" "$DURATION"
