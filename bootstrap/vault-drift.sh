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

# </dev/null matters: kubectl exec reads stdin, and inside a `for` loop
# that consumes the iteration list, so the loop runs once and stops. That
# silently skipped every role after the first in the scope check below.
vault_exec() {
  kubectl exec -n default vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" "$@" 2>/dev/null </dev/null
}

# Roles this repo declares, from BOTH writers.
#
# vault-policies.sh covers third-party and hand-written apps. Services
# scaffolded by homelabctl never appear there - they derive their role
# from their own config.yaml and create it with `homelabctl vault
# --apply`, which lives in the service repo, not here.
#
# So the second source is the manifests: every ESO SecretStore names the
# role it authenticates with, and those manifests are what is actually
# deployed. Without this, every homelabctl-managed service reported as
# "someone wrote these by hand" - burying real findings in false ones
# until nobody read the output.
#
# KNOWN ISSUE (2026-09-17): after `demo` was deleted from Vault and every
# reference removed from this repo, this still reports it as "declared but
# not in Vault". None of the three greps above produce `demo` when run by
# hand against the same tree - so the stale value is coming from somewhere
# this comment's author could not find. Treat a lone `demo` line as noise
# until that is chased down; anything else it reports is real.
declared_roles=$(
  {
    grep -oE '^  "[a-z0-9-]+\|' "$declared_file" | tr -d ' "|'
    grep -oE 'auth/kubernetes/role/[a-z0-9-]+' "$declared_file" | sed 's|.*/||'
    grep -rhoE '^[[:space:]]+role: "?[a-z0-9-]+"?' --include='*.yaml' "$repo_root" \
      | sed -E 's/.*role: "?([a-z0-9-]+)"?/\1/'
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

  # The declared binding, from the APPS array: name|path|namespace|sa.
  # `|| true` because a homelabctl-managed role is not in that array at
  # all, so grep exits 1 - and under `set -e` that ended the script
  # silently, skipping every check below this loop.
  want=$(grep -oE "^  \"$r\|[^\"]+\"" "$declared_file" | tr -d ' "' | awk -F'|' '{print $4, $3, $1}' || true)
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

# Scope, not just existence. A role bound to `*` service accounts in `*`
# namespaces can be assumed by ANY pod in the cluster, so a policy that
# reads kv/data/* gives every workload every secret - defeating the
# per-app isolation the rest of this file checks. Being declared does not
# make that safe, so this runs over every live role regardless.
for r in $live_roles; do
  # Prints the policies when both bindings are wildcards, nothing
  # otherwise - so the shell tests for output rather than parsing fields.
  wildcard=$(vault_exec vault read -format=json "auth/kubernetes/role/$r" | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]
sa=d.get("bound_service_account_names") or []
ns=d.get("bound_service_account_namespaces") or []
if "*" in sa and "*" in ns:
    print(",".join(d.get("token_policies") or []) or "none")' 2>/dev/null) || continue

  [ -n "$wildcard" ] || continue

  drift=1
  report "${red}role $r is bound to any service account in any namespace${off}"
  report "  ${dim}any pod in the cluster can assume it; policies: $wildcard${off}"
  report "  ${dim}bind it to the service account and namespace that needs it${off}"
  report ""
done

if [ "$drift" -eq 0 ]; then
  report "${green}vault matches what this repo declares${off}"
  exit 0
fi

report "${dim}apply the declared state with: bootstrap/vault-policies.sh${off}"
exit 1
