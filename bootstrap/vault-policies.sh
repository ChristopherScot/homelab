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
# Single-path roles are defined here. The homepage role reads from
# multiple kv paths and is declared separately below.
APPS=(
  "synology-csi|kv/data/synology/*|synology-csi|external-secrets-sa"
  "authelia|kv/data/authelia/*|authelia|external-secrets-sa"
  "cert-manager|kv/data/cert-manager/*|cert-manager|external-secrets-sa"
  "gluetun|kv/data/nordvpn/*|media|external-secrets-sa"
  "arr|kv/data/arr/*|media|external-secrets-sa"
  "qbittorrent|kv/data/qbittorrent/*|media|external-secrets-sa"
  "jellyfin|kv/data/jellyfin/*|media|external-secrets-sa"
  "jellyseerr|kv/data/jellyseerr/*|media|external-secrets-sa"
)

# Cross-app role for media: lets the mam-exporter sidecar read the shared
# grafana-cloud token to push MAM metrics via Prometheus remote_write.
# Kept separate from the per-app roles above because grafana-cloud lives
# outside any single arr-stack app's Vault path.
vault policy write media-grafana-cloud - <<EOF
path "kv/data/grafana-cloud"     { capabilities = ["read"] }
path "kv/metadata/grafana-cloud" { capabilities = ["read", "list"] }
EOF
vault write auth/kubernetes/role/media-grafana-cloud \
  bound_service_account_names="external-secrets-sa" \
  bound_service_account_namespaces="media" \
  policies="media-grafana-cloud" \
  ttl=1h

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

# homepage reads keys for every app it shows widgets for. Distinct from
# the per-app roles above because it spans namespaces.
vault policy write homepage - <<EOF
path "kv/data/arr/*"             { capabilities = ["read"] }
path "kv/metadata/arr/*"         { capabilities = ["read", "list"] }
path "kv/data/jellyfin/*"        { capabilities = ["read"] }
path "kv/metadata/jellyfin/*"    { capabilities = ["read", "list"] }
path "kv/data/jellyseerr/*"      { capabilities = ["read"] }
path "kv/metadata/jellyseerr/*"  { capabilities = ["read", "list"] }
path "kv/data/qbittorrent/*"     { capabilities = ["read"] }
path "kv/metadata/qbittorrent/*" { capabilities = ["read", "list"] }
EOF
vault write auth/kubernetes/role/homepage \
  bound_service_account_names="external-secrets-sa" \
  bound_service_account_namespaces="homepage" \
  policies="homepage" \
  ttl=1h

# Human auth: OIDC via Authelia (below). Userpass was a stepping-stone;
# the root token + unseal keys are the break-glass. Disable userpass if
# previously enabled.
vault auth list 2>/dev/null | grep -q '^userpass/' && \
  vault auth disable userpass || true

vault policy write admin - <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

# OIDC against Authelia. Client secret is read from Vault KV (where it was
# generated alongside the Authelia hmac/jwks/hashed-client-secret). The
# OIDC role is locked to user "chris" via bound_claims; Authelia's
# vault_admin authorization_policy enforces the same at its end.
vault auth list 2>/dev/null | grep -q '^oidc/' || \
  vault auth enable oidc

OIDC_CLIENT_SECRET=$(vault kv get -field=oidc_vault_client_secret kv/authelia/keys 2>/dev/null || true)
if [ -n "$OIDC_CLIENT_SECRET" ]; then
  vault write auth/oidc/config \
    oidc_discovery_url="https://auth.home.chrisscotmartin.com" \
    oidc_client_id="vault" \
    oidc_client_secret="$OIDC_CLIENT_SECRET" \
    default_role="admin"

  # bound_claims is a map; vault CLI parses it from stdin JSON.
  # oidc_scopes triggers a UserInfo fetch + claim merge, which is needed
  # because Authelia keeps preferred_username/groups in UserInfo by default.
  cat <<'JSON' | vault write auth/oidc/role/admin -
{
  "role_type": "oidc",
  "user_claim": "preferred_username",
  "groups_claim": "groups",
  "oidc_scopes": ["profile", "groups", "email"],
  "bound_audiences": ["vault"],
  "bound_claims_type": "string",
  "bound_claims": {"preferred_username": "chris"},
  "allowed_redirect_uris": [
    "https://vault.home.chrisscotmartin.com/ui/vault/auth/oidc/oidc/callback",
    "https://vault.home.chrisscotmartin.com/oidc/callback"
  ],
  "policies": ["admin"],
  "ttl": "1h"
}
JSON
fi

echo "done"
