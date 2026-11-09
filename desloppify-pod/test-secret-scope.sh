#!/usr/bin/env bash
# The pod gets these credentials and no others.
#
# An ExternalSecret that names a Vault `key` without a `property` pulls
# every field at that path. kv/claude-pods/desloppify holds a GitHub PAT
# alongside the Claude tokens, so a secret written that way would hand
# the agent a credential nobody decided to give it.
#
# Each entry must therefore name its property, and the set of properties
# must be the ones intended - so widening the grant is a visible edit to
# this list rather than a quiet consequence of a manifest change.
set -uo pipefail
fail=0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$here/desloppify-secrets.yaml"

EXPECTED="claude_oauth_token
claude_oauth_token_personal
github_token"

# Every remoteRef names a property.
refs=$(grep -c "remoteRef" "$manifest")
props=$(grep -c "property:" "$manifest")
if [ "$refs" -ne "$props" ]; then
  echo "FAIL: $refs remoteRef(s) but only $props property declaration(s)"
  echo "      a remoteRef without a property pulls every field at that path"
  fail=1
fi

got=$(grep -oE "property: [a-z_]+" "$manifest" | awk '{print $2}' | sort -u)
if [ "$got" != "$EXPECTED" ]; then
  echo "FAIL: the granted properties changed."
  echo "--- expected ---"; printf '%s\n' "$EXPECTED"
  echo "--- found ---";    printf '%s\n' "$got"
  echo "If this is intended, update EXPECTED here and say why in the commit."
  fail=1
fi

# And nothing may mount a secret this pod has no business holding.
for forbidden in gcp-deploy claude-git-creds kernel-api kaneo-api claude-repos; do
  if grep -q "secretName: $forbidden" "$here/desloppify-statefulset.yaml" 2>/dev/null; then
    echo "FAIL: the pod mounts '$forbidden', which is not its credential"
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "PASS - every remoteRef is property-scoped, the grant is the expected 3, no foreign secrets"
exit "$fail"
