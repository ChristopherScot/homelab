#!/bin/bash
# Idempotent: declares per-app Vault policies + Kubernetes auth roles for
# external-secrets. Run after Vault is initialized + unsealed.
#
# Pattern: each app gets a narrow policy granting read on its own kv path,
# bound to a specific service account in a specific namespace. Compromise
# of one pod does not expose other apps' secrets.
#
# Usage, from a host that can reach Vault:
#   vault login              # OIDC via Authelia; writes ~/.vault-token
#   ./bootstrap/vault-policies.sh
#
# Nothing else to export. VAULT_ADDR defaults to the port-forward address,
# and the token is read from ~/.vault-token the same way every other vault
# command reads it. Set VAULT_TOKEN explicitly to override (CI, or the
# break-glass root token).
#
# This cannot be piped into the vault pod -- `kubectl exec ... -- sh <
# this-file` runs it where there is no token and no ~/.vault-token, so it
# exits on the check below.

set -euo pipefail

: "${VAULT_ADDR:=http://127.0.0.1:8200}"
: "${VAULT_TOKEN:=$(cat "${HOME}/.vault-token" 2>/dev/null || true)}"
: "${VAULT_TOKEN:?no token - run 'vault login' first, or set VAULT_TOKEN}"
export VAULT_ADDR VAULT_TOKEN

vault auth list 2>/dev/null | grep -q '^kubernetes/' || \
  vault auth enable kubernetes

# Third-party and hand-written apps only. Services scaffolded by
# homelabctl derive their own role from their config.yaml - run
# `homelabctl vault --apply` in the service directory rather than adding a
# line here, or the role ends up declared in two places that can disagree.
#
# This script is the declaration; re-running it is idempotent and is how
# you reconcile. There used to be a vault-drift.sh that compared it to
# live Vault from a pre-push hook, removed 2026-09-17: it reported four
# legitimate roles as hand-written, hid a real finding in that noise, and
# a `set -euo pipefail` bug meant it had been silently skipping most of
# its own checks. A check you have to remember to distrust is worse than
# none.
#
# The gap it was covering is still real - Vault auth roles are not
# Kubernetes objects, so nothing reconciles them and no diff shows them.
# What shrank the gap is homelabctl: for every service it manages the
# config.yaml IS the declaration, so there is nothing here to drift from.
#
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
  "picoshare|kv/data/picoshare/*|picoshare|external-secrets-sa"
  "kaneo|kv/data/kaneo/*|kaneo|external-secrets-sa"
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

# ddns updates the ntfy WAN A record and reuses cert-manager's Route 53
# credential rather than a second AWS key, so it reads from other apps'
# kv paths instead of a kv/ddns/* of its own: route53 for the DNS update,
# ntfy/config for the token it notifies with. Read-only, bound to the ddns
# namespace's SA.
#
# The ntfy grant was missing until 2026-11-10. ddns-secrets pulls four
# keys, three from cert-manager/route53 and grafana_token from ntfy/config,
# and Vault denied the whole read for the one ungranted path -- a 403 that
# reads as an auth failure rather than a missing grant.
#
# The other half of this pair is the ExternalSecret in
# ChristopherScot/ddns (deploy/ddns/externalsecret.yaml), which declares
# the paths ddns reads. Nothing compares the two, so adding a path there
# without adding it here fails exactly this way. ddns is hand-written
# rather than homelabctl-scaffolded, so it has no config.yaml to derive
# this from.
vault policy write ddns - <<EOF
path "kv/data/cert-manager/route53"     { capabilities = ["read"] }
path "kv/metadata/cert-manager/route53" { capabilities = ["read", "list"] }
path "kv/data/ntfy/config"              { capabilities = ["read"] }
path "kv/metadata/ntfy/config"          { capabilities = ["read", "list"] }
EOF

# Binds "ddns", not the "external-secrets-sa" every other app role uses.
# ddns's manifests live in the ChristopherScot/ddns repo (deploy/ddns) and
# its SecretStore authenticates as the "ddns" ServiceAccount; there is no
# external-secrets-sa in that namespace at all, so the previous binding
# could never match. Vault answered every login with
#   403 ... * service account name not authorized
# and ddns-secrets stopped refreshing. The already-issued Secret kept
# working, so this surfaced only as a >15m sync-failure alert rather than
# an outage.
vault write auth/kubernetes/role/ddns \
  bound_service_account_names="ddns" \
  bound_service_account_namespaces="ddns" \
  policies="ddns" \
  ttl=1h

# Authelia gets an extra grant for shared SES SMTP creds (used by its
# notifier.smtp config). The per-app loop above only sets one path per
# policy; re-write here to include kv/authelia/*, kv/ses/* and
# kv/cnpg-backups/*. Re-write (not append): Vault policies are
# replace-on-write.
#
# cnpg-backups/* follows the vaultwarden and paperless pattern - the app's
# own role reads the shared S3 creds, rather than the separate cnpg-backup
# ServiceAccount used by shlink/monitoring/pokedex/kaneo. authelia-db
# (authelia/db.yaml) backs up to s3://cscot-homelab-pg-backups/authelia via
# the authelia-db-backup-s3 ExternalSecret, which authenticates through the
# vault-authelia SecretStore - so the grant has to live on this policy.
# Without it Vault allowed the login and then refused the read with
#   403 ... * permission denied   on kv/data/cnpg-backups/s3
# The previously-issued Secret kept the backups running, so this showed up
# as a sync-failure alert rather than a backup outage.
#
# The metadata path was also wrong: kv/data/authelia/metadata/* is a data
# path that happens to contain the word "metadata", not the KV v2 metadata
# endpoint. LIST on kv/authelia/* never actually worked.
vault policy write authelia - <<EOF
path "kv/data/authelia/*"         { capabilities = ["read"] }
path "kv/metadata/authelia/*"     { capabilities = ["read", "list"] }
path "kv/data/ses/*"              { capabilities = ["read"] }
path "kv/metadata/ses/*"          { capabilities = ["read", "list"] }
path "kv/data/cnpg-backups/*"     { capabilities = ["read"] }
path "kv/metadata/cnpg-backups/*" { capabilities = ["read", "list"] }
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

# garage: in-cluster S3. Reads only its own RPC secret; the S3 access
# keys it mints for clients are read by those clients' policies, not
# this one.
vault policy write garage - <<EOF
path "kv/data/garage/*"     { capabilities = ["read"] }
path "kv/metadata/garage/*" { capabilities = ["read", "list"] }
EOF
vault write auth/kubernetes/role/garage \
  bound_service_account_names="external-secrets-sa" \
  bound_service_account_namespaces="garage" \
  policies="garage" \
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

# CNPG backup credentials, one role per namespace holding a Postgres
# cluster that backs up to S3.
#
# Deliberately NOT folded into an app's own role. shlink-redirector's
# policy is generated by homelabctl from its config.yaml and grants only
# kv/shlink/*, so a hand-edit here would be overwritten on the next
# `homelabctl vault --apply`. More to the point, shlink-db is declared in
# cloudnative-pg-clusters/, not in the redirector's config - the database
# is not the redirector's concern, and neither are its backup creds.
#
# Each role binds a dedicated ServiceAccount (cnpg-backup) rather than the
# external-secrets-sa the app roles use, so the grant cannot be picked up
# by anything else in the namespace.
for ns in shlink monitoring pokedex kaneo; do
  vault policy write "cnpg-backup-$ns" - <<EOF
path "kv/data/cnpg-backups/*"     { capabilities = ["read"] }
path "kv/metadata/cnpg-backups/*" { capabilities = ["read", "list"] }
EOF

  vault write "auth/kubernetes/role/cnpg-backup-$ns" \
    bound_service_account_names="cnpg-backup" \
    bound_service_account_namespaces="$ns" \
    policies="cnpg-backup-$ns" \
    ttl=1h
done

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

# Separate entrypoint also permits reconciling just this role during rollout.
bash "$(dirname -- "${BASH_SOURCE[0]}")/codex-vault.sh"

echo "done"
