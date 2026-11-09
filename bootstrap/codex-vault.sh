#!/usr/bin/env bash
# Reconcile the Codex-specific Vault role. No Kubernetes objects are changed.
# Uses the operator's existing Vault login; login secrets are seeded separately.
set -euo pipefail
bootstrap_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
vault policy write codex-pods "$bootstrap_dir/codex-vault-policy.hcl"
vault write auth/kubernetes/role/codex-pods \
  bound_service_account_names=external-secrets-sa \
  bound_service_account_namespaces=codex-pods \
  policies=codex-pods ttl=1h
