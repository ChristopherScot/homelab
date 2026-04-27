#!/bin/bash
# Idempotent: declares per-app Vault policies + Kubernetes auth roles for
# external-secrets. Run after Vault is initialized + unsealed.
#
# Pattern: each app gets a narrow policy granting read on its own kv path,
# bound to a specific service account in a specific namespace. Compromise
# of one pod does not expose other apps' secrets.
#
# Usage (from a host that can reach the vault pod):
#   export VAULT_ADDR="http://127.0.0.1:8200"
#   export VAULT_TOKEN="<root or admin token>"
#   kubectl port-forward -n default svc/vault 8200:8200 &
#   ./bootstrap/vault-policies.sh
#
# Or exec inside the vault pod:
#   kubectl exec -n default vault-0 -- sh < bootstrap/vault-policies.sh

set -euo pipefail

: "${VAULT_ADDR:=http://127.0.0.1:8200}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"
export VAULT_ADDR VAULT_TOKEN

vault auth list 2>/dev/null | grep -q '^kubernetes/' || \
  vault auth enable kubernetes

# Each entry: <app-name>|<kv-path-glob>|<bound-namespace>|<bound-sa>
APPS=(
  "synology-csi|kv/data/synology/*|synology-csi|external-secrets-sa"
  "gluetun|kv/data/nordvpn/*|media|external-secrets-sa"
)

for entry in "${APPS[@]}"; do
  IFS='|' read -r app path ns sa <<<"$entry"

  vault policy write "$app" - <<EOF
path "$path" {
  capabilities = ["read"]
}
path "${path%/\*}/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

  vault write "auth/kubernetes/role/$app" \
    bound_service_account_names="$sa" \
    bound_service_account_namespaces="$ns" \
    policies="$app" \
    ttl=1h
done

echo "done"
