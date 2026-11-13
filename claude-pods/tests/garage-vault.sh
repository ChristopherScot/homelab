#!/usr/bin/env bash
# The targeted handoff must not rewrite unrelated apps or grant Vault writes.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/policies"
cat > "$tmp/bin/vault" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GARAGE_VAULT_CALLS"
case "$1 $2" in
  'policy write') cat > "$GARAGE_VAULT_POLICIES/$3" ;;
  'write auth/kubernetes/role/garage'|'write auth/kubernetes/role/claude-pods') ;;
  *) echo "Unexpected Vault operation" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/vault"
export GARAGE_VAULT_CALLS="$tmp/calls" GARAGE_VAULT_POLICIES="$tmp/policies"
export VAULT_TOKEN=fixture VAULT_ADDR=http://vault.invalid
export PATH="$tmp/bin:$PATH"
bash "$root/bootstrap/vault-policies.sh" --garage-only
[ "$(wc -l < "$tmp/calls" | tr -d ' ')" = 4 ]
grep -qF 'bound_service_account_namespaces=garage policies=garage ttl=1h' "$tmp/calls"
grep -qF 'bound_service_account_namespaces=claude-pods policies=claude-pods ttl=1h' "$tmp/calls"
grep -qF 'bound_service_account_names=external-secrets-sa' "$tmp/calls"
grep -qF 'kv/data/garage/rpc' "$tmp/policies/garage"
if grep -qF 's3-' "$tmp/policies/garage"; then exit 1; fi
for path in 'kv/data/claude-pods/*' 'kv/metadata/claude-pods/*' 'kv/data/garage/s3-reference' 'kv/data/garage/s3-seed'; do
  grep -qF "$path" "$tmp/policies/claude-pods"
done
if grep -qF 'garage/*' "$tmp/policies/claude-pods"; then exit 1; fi
if grep -qF 'garage/rpc' "$tmp/policies/claude-pods"; then exit 1; fi
if grep -Eq '"(create|update|delete|sudo)"' "$tmp/policies/"*; then exit 1; fi
: > "$tmp/calls"
if bash "$root/bootstrap/vault-policies.sh" --unknown > /dev/null 2>&1; then
  echo 'FAIL: unknown scope must be refused' >&2; exit 1
fi
[ ! -s "$tmp/calls" ]
echo 'PASS: Garage handoff touches only its two bound roles and read-only policies'
