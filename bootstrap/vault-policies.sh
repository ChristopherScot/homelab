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
  "vaultwarden|kv/data/vaultwarden/*|vaultwarden|external-secrets-sa"
  "paperless|kv/data/paperless/*|paperless|external-secrets-sa"
  "dead-mans-switch|kv/data/dead-mans-switch/*|dead-mans-switch|external-secrets-sa"
  "longhorn|kv/data/longhorn/*|longhorn-system|external-secrets-sa"
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

# Authelia gets an extra grant for shared SES SMTP creds (used by its
# notifier.smtp config). The per-app loop above only sets one path per
# policy; re-write here to include both kv/authelia/* and kv/ses/*.
# Re-write (not append) because Vault policies are replace-on-write.
vault policy write authelia - <<EOF
path "kv/data/authelia/*"          { capabilities = ["read"] }
path "kv/data/authelia/metadata/*" { capabilities = ["read", "list"] }
path "kv/data/ses/*"               { capabilities = ["read"] }
path "kv/metadata/ses/*"           { capabilities = ["read", "list"] }
EOF

# Monitoring reads grafana-local creds, shared SES SMTP (alert emails), and the
# ntfy grafana_token (webhook contact points for ntfy alerts). mcp-grafana and
# Alloy collectors bind to the same role via external-secrets-sa in monitoring.
vault policy write monitoring - <<EOF
path "kv/data/grafana-local"     { capabilities = ["read"] }
path "kv/metadata/grafana-local" { capabilities = ["read", "list"] }
path "kv/data/ses/*"             { capabilities = ["read"] }
path "kv/metadata/ses/*"         { capabilities = ["read", "list"] }
path "kv/data/ntfy/*"            { capabilities = ["read"] }
path "kv/metadata/ntfy/*"        { capabilities = ["read", "list"] }
EOF
vault write auth/kubernetes/role/monitoring \
  bound_service_account_names="external-secrets-sa" \
  bound_service_account_namespaces="monitoring" \
  policies="monitoring" \
  ttl=1h

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

# Gluetun-vpn role lets the in-cluster gluetun sidecar read its WireGuard
# private key (Proton) and the gluetun HTTP API key. Multi-path because
# kv/protonvpn/* and kv/gluetun/* are separate.
vault policy write gluetun-vpn - <<EOF
path "kv/data/protonvpn/*"     { capabilities = ["read"] }
path "kv/metadata/protonvpn/*" { capabilities = ["read", "list"] }
path "kv/data/gluetun/*"       { capabilities = ["read"] }
path "kv/metadata/gluetun/*"   { capabilities = ["read", "list"] }
EOF
vault write auth/kubernetes/role/gluetun-vpn \
  bound_service_account_names="external-secrets-sa" \
  bound_service_account_namespaces="media" \
  policies="gluetun-vpn" \
  ttl=1h

# Shelfmark needs both prowlarr API key (under kv/arr/) and qbit creds
# (under kv/qbittorrent/) to render its settings.json — multi-path role
# like homepage.
vault policy write shelfmark - <<EOF
path "kv/data/arr/api-keys"        { capabilities = ["read"] }
path "kv/metadata/arr/api-keys"    { capabilities = ["read", "list"] }
path "kv/data/qbittorrent/*"       { capabilities = ["read"] }
path "kv/metadata/qbittorrent/*"   { capabilities = ["read", "list"] }
EOF
vault write auth/kubernetes/role/shelfmark \
  bound_service_account_names="external-secrets-sa" \
  bound_service_account_namespaces="media" \
  policies="shelfmark" \
  ttl=1h

# Media-cleanup needs arr api keys, jellyfin admin key, jellyseerr admin key
# to fan out a single delete across cluster + q-stack instances.
vault policy write media-cleanup - <<EOF
path "kv/data/arr/*"          { capabilities = ["read"] }
path "kv/metadata/arr/*"      { capabilities = ["read", "list"] }
path "kv/data/jellyfin/*"     { capabilities = ["read"] }
path "kv/metadata/jellyfin/*" { capabilities = ["read", "list"] }
path "kv/data/jellyseerr/*"   { capabilities = ["read"] }
path "kv/metadata/jellyseerr/*" { capabilities = ["read", "list"] }
EOF
vault write auth/kubernetes/role/media-cleanup \
  bound_service_account_names="external-secrets-sa" \
  bound_service_account_namespaces="media" \
  policies="media-cleanup" \
  ttl=1h

# Autocaliweb reads shared SES SMTP transport creds (kv/ses/smtp — host,
# port, username, password only; sender is hardcoded per-app in the
# ExternalSecret/init container) to write Calibre-Web's mail_* settings
# into /config/app.db at pod start.
vault policy write autocaliweb - <<EOF
path "kv/data/ses/*"      { capabilities = ["read"] }
path "kv/metadata/ses/*"  { capabilities = ["read", "list"] }
EOF
vault write auth/kubernetes/role/autocaliweb \
  bound_service_account_names="external-secrets-sa" \
  bound_service_account_namespaces="media" \
  policies="autocaliweb" \
  ttl=1h

# Vaultwarden + Paperless: their own kv path PLUS shared SES SMTP transport
# (kv/ses/*) so they can send mail (Vaultwarden invites/password resets,
# Paperless share/notify). Re-write here (not in the APPS loop) because the
# loop only grants a single path; sender addresses are hardcoded per-app in
# each SMTP ExternalSecret, not in Vault.
# vaultwarden + paperless also read kv/cnpg-backups/* — the shared S3
# creds their CNPG clusters use for continuous backup to S3 (Barman).
vault policy write vaultwarden - <<EOF
path "kv/data/vaultwarden/*"     { capabilities = ["read"] }
path "kv/metadata/vaultwarden/*" { capabilities = ["read", "list"] }
path "kv/data/ses/*"             { capabilities = ["read"] }
path "kv/metadata/ses/*"         { capabilities = ["read", "list"] }
path "kv/data/cnpg-backups/*"     { capabilities = ["read"] }
path "kv/metadata/cnpg-backups/*" { capabilities = ["read", "list"] }
EOF
vault write auth/kubernetes/role/vaultwarden \
  bound_service_account_names="external-secrets-sa" \
  bound_service_account_namespaces="vaultwarden" \
  policies="vaultwarden" \
  ttl=1h

vault policy write paperless - <<EOF
path "kv/data/paperless/*"     { capabilities = ["read"] }
path "kv/metadata/paperless/*" { capabilities = ["read", "list"] }
path "kv/data/ses/*"           { capabilities = ["read"] }
path "kv/metadata/ses/*"       { capabilities = ["read", "list"] }
path "kv/data/cnpg-backups/*"     { capabilities = ["read"] }
path "kv/metadata/cnpg-backups/*" { capabilities = ["read", "list"] }
EOF
vault write auth/kubernetes/role/paperless \
  bound_service_account_names="external-secrets-sa" \
  bound_service_account_namespaces="paperless" \
  policies="paperless" \
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
    "https://vault.home.chrisscotmartin.com/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ],
  "policies": ["admin"],
  "ttl": "1h"
}
JSON
fi

echo "done"
