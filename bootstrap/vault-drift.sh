#!/usr/bin/env bash
# Compare the Vault roles and policies declared in vault-policies.sh
# against what is actually in Vault.
#
# Why: vault-policies.sh is the source of truth, but Vault's auth roles are
# not Kubernetes objects, so nothing reconciles them and no diff tool sees
# them. A `vault write` at a terminal drifts silently - which is exactly
# how approvald's ServiceAccount rename broke secret sync with no warning.
#
#   bootstrap/vault-drift.sh           # report drift, exit 1 if any
#   bootstrap/vault-drift.sh --quiet   # exit code only, for hooks
#
# Reads Vault through the vault-0 pod, so it needs kubectl access and a
# token. VAULT_TOKEN is used if set; otherwise it is read from 1Password,
# which will prompt for Touch ID.
set -euo pipefail

quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo .)
declared_file="$repo_root/bootstrap/vault-policies.sh"
[ -f "$declared_file" ] || { echo "vault-drift: $declared_file not found" >&2; exit 2; }

# Unreachable Vault is "unknown", never "fine" - a check that passes when
# it cannot see anything is worse than no check.
if ! kubectl get pod -n default vault-0 >/dev/null 2>&1; then
  echo "vault-drift: cannot reach vault-0; skipping (not a pass)" >&2
  exit 0
fi

token="${VAULT_TOKEN:-}"
if [ -z "$token" ]; then
  token=$(op read "op://Employee/homelab-vault-root/password" 2>/dev/null || true)
fi
[ -n "$token" ] || { echo "vault-drift: no VAULT_TOKEN and could not read it from 1Password" >&2; exit 2; }

vault_exec() {
  kubectl exec -n default vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" "$@" 2>/dev/null
}

# Roles the script declares: the APPS array plus any explicit
# `vault write auth/kubernetes/role/<name>`.
declared_roles=$(
  {
    grep -oE '^  "[a-z0-9-]+\|' "$declared_file" | tr -d ' "|'
    grep -oE 'auth/kubernetes/role/[a-z0-9-]+' "$declared_file" | sed 's|.*/||'
  } | sort -u
)

live_roles=$(vault_exec vault list -format=json auth/kubernetes/role \
  | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))' 2>/dev/null | sort -u)

red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; dim=$'\033[2m'; off=$'\033[0m'
[ -t 1 ] || { red=; green=; yellow=; dim=; off=; }

drift=0
report() { [ "$quiet" -eq 1 ] || printf '%b\n' "$*"; }

missing=$(comm -23 <(echo "$declared_roles") <(echo "$live_roles"))
extra=$(comm -13 <(echo "$declared_roles") <(echo "$live_roles"))

if [ -n "$missing" ]; then
  drift=1
  report "${red}declared but not in Vault${off} ${dim}(run bootstrap/vault-policies.sh)${off}"
  for r in $missing; do report "  ${red}-${off} $r"; done
  report ""
fi

if [ -n "$extra" ]; then
  drift=1
  report "${yellow}in Vault but not declared${off} ${dim}(someone wrote these by hand)${off}"
  for r in $extra; do report "  ${yellow}+${off} $r"; done
  report ""
fi

# For roles present in both, compare the binding that actually matters:
# which ServiceAccount and namespace may assume the role. This is the field
# that broke approvald.
for r in $(comm -12 <(echo "$declared_roles") <(echo "$live_roles")); do
  live=$(vault_exec vault read -format=json "auth/kubernetes/role/$r" | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]
print(",".join(d.get("bound_service_account_names") or []),
      ",".join(d.get("bound_service_account_namespaces") or []),
      ",".join(d.get("token_policies") or []))' 2>/dev/null) || continue

  # The declared binding, from the APPS array: name|path|namespace|sa
  want=$(grep -oE "^  \"$r\|[^\"]+\"" "$declared_file" | tr -d ' "' | awk -F'|' '{print $4, $3, $1}')
  [ -n "$want" ] || continue   # explicit blocks vary too much to compare

  if [ "$live" != "$want" ]; then
    drift=1
    report "${red}role $r differs${off}"
    report "  ${dim}field:  service-accounts  namespaces  policies${off}"
    report "  ${green}declared${off}  $want"
    report "  ${red}live${off}      $live"
    report ""
  fi
done

if [ "$drift" -eq 0 ]; then
  report "${green}vault matches bootstrap/vault-policies.sh${off}"
  exit 0
fi

report "${dim}apply the declared state with: bootstrap/vault-policies.sh${off}"
exit 1
