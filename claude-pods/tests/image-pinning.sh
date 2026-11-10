#!/usr/bin/env bash
# One image-pull story for our own images (claude-pod, desloppify-pod):
# pull exactly when a build lands, hit the node cache on every other
# start. The pieces that make that true are spread over four places,
# and each one failing is silent - the cluster keeps running, just on
# the wrong image or the wrong pull behaviour:
#
#   1. claude-pods/ and desloppify-pod/ are kustomizations that list
#      every top-level manifest. Kustomize mode is what lets the image
#      updater pin a digest on the live Application; it also means a
#      manifest missing from resources: is simply not deployed.
#   2. Every ref to our own images is IfNotPresent. On a digest that is
#      pull-on-change, cache otherwise; Always on :latest contacted ghcr
#      on every wake (one hung 31 minutes) and still ran stale code.
#   3. The Application carries the updater annotations, including the
#      pull secret - the images are private and without it the registry
#      poll 401s forever - and the updater is granted that one secret.
#   4. The root app-of-apps ignores /spec/source/kustomize on children
#      with RespectIgnoreDifferences, or selfHeal reverts every digest
#      within seconds (apps/_homelabctl-services.yaml records that).
#
# Run: claude-pods/tests/image-pinning.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
fail=0

fail() {
  echo "FAIL: $*"
  fail=1
}

# dir  alias  app-file
apps=(
  "claude-pods claude-pod app-of-apps/apps/claude-pods.yaml"
  "desloppify-pod desloppify-pod app-of-apps/apps/desloppify-pod.yaml"
)
# Only our own images get the digest story; sidecars from other
# registries keep whatever policy they have.
ours='^ghcr\.io/christopherscot/'

for entry in "${apps[@]}"; do
  read -r dir alias app <<<"$entry"
  kz="$repo/$dir/kustomization.yaml"
  app="$repo/$app"

  # 1. A kustomization that enumerates every top-level manifest.
  [ -f "$kz" ] || { fail "$dir/kustomization.yaml is missing"; continue; }
  for f in "$repo/$dir"/*.yaml; do
    name=$(basename "$f")
    [ "$name" = kustomization.yaml ] && continue
    yq -e ".resources[] | select(. == \"$name\")" "$kz" >/dev/null 2>&1 ||
      fail "$dir/kustomization.yaml does not list $name - it will not be deployed"
  done
  rendered=$(kubectl kustomize "$repo/$dir") || { fail "$dir does not render"; continue; }

  image=$(yq '.metadata.annotations["argocd-image-updater.argoproj.io/image-list"]' "$app")
  [ "$image" = "$alias=ghcr.io/christopherscot/$alias:latest" ] ||
    fail "$app image-list is '$image', expected $alias=ghcr.io/christopherscot/$alias:latest"
  image=${image#*=}; image=${image%:latest}

  yq -e ".images[] | select(.name == \"$image\")" "$kz" >/dev/null 2>&1 ||
    fail "$dir/kustomization.yaml has no images: entry for $image, so the updater's override has nothing to replace"

  # The rendered refs must be exactly what git says: the digest is
  # substituted on the live Application, never in CI.
  refs=$(printf '%s\n' "$rendered" |
    yq -N '.. | select(type == "!!map" and has("image") and has("name")) | .image + " " + (.imagePullPolicy // "<unset>")' |
    grep -E "^$ours" | sort -u)
  [ -n "$refs" ] || fail "$dir renders no reference to our own images"
  while read -r ref policy; do
    [ "$ref" = "$image:latest" ] || fail "$dir renders $ref, expected $image:latest"
    # 2. IfNotPresent at every ref.
    [ "$policy" = IfNotPresent ] || fail "$dir: $ref has imagePullPolicy $policy, expected IfNotPresent"
  done <<<"$refs"

  # 3. Updater annotations on the Application.
  for kv in \
    "$alias.update-strategy=digest" \
    "$alias.pull-secret=pullsecret:claude-pods/ghcr-pull" \
    "write-back-method=argocd"; do
    key="argocd-image-updater.argoproj.io/${kv%%=*}"
    want=${kv#*=}
    got=$(yq ".metadata.annotations[\"$key\"]" "$app")
    [ "$got" = "$want" ] || fail "$app: annotation $key is '$got', expected '$want'"
  done
done

# 3b. The updater's own RBAC stops at the argocd namespace; the pull
#     secret is in claude-pods, so it needs get on that one secret.
cp_rendered=$(kubectl kustomize "$repo/claude-pods" 2>/dev/null)
role=$(printf '%s\n' "$cp_rendered" | yq -N '
  select(.kind == "Role" and .metadata.namespace == "claude-pods")
  | select(.rules | any_c(
      (.resources | contains(["secrets"]))
      and (.resourceNames | contains(["ghcr-pull"]))
      and (.verbs | contains(["get"]))))
  | .metadata.name' | head -1)
[ -n "$role" ] || fail "no Role in claude-pods grants get on secret ghcr-pull"
if [ -n "$role" ]; then
  printf '%s\n' "$cp_rendered" | yq -e -N "
    select(.kind == \"RoleBinding\" and .metadata.namespace == \"claude-pods\")
    | select(.roleRef.kind == \"Role\" and .roleRef.name == \"$role\")
    | select(.subjects | any_c(.kind == \"ServiceAccount\" and .name == \"argocd-image-updater\" and .namespace == \"argocd\"))
    | .metadata.name" >/dev/null 2>&1 ||
    fail "Role $role is not bound to argocd:argocd-image-updater"
fi

# 4. The root app leaves /spec/source/kustomize to the updater.
root="$repo/app-of-apps/app-of-apps.yaml"
yq -e '.spec.ignoreDifferences[]
  | select(.group == "argoproj.io" and .kind == "Application")
  | .jsonPointers[] | select(. == "/spec/source/kustomize")' "$root" >/dev/null 2>&1 ||
  fail "$root does not ignore /spec/source/kustomize on child Applications; selfHeal will revert every digest"
yq -e '.spec.syncPolicy.syncOptions[] | select(. == "RespectIgnoreDifferences=true")' "$root" >/dev/null 2>&1 ||
  fail "$root lacks RespectIgnoreDifferences=true; the ignore applies to diffs but not to syncs"
# The file's own comment explains why pruning here would cascade into
# every child's resources. Being in the file is how it gets added.
[ "$(yq '.spec.syncPolicy.automated.prune' "$root")" = null ] ||
  fail "$root sets automated.prune; see the comment in that file"

[ "$fail" -eq 0 ] && echo "PASS - both apps digest-pinned, IfNotPresent at every ref, updater can read the pull secret, root app leaves the digest alone"
exit "$fail"
