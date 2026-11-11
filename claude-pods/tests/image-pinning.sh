#!/usr/bin/env bash
# Our own images (claude-pod, desloppify-pod) are digest-pinned by
# argocd-image-updater. Four pieces make that true, and each one failing
# is silent - the cluster keeps running, on the wrong image or with the
# wrong pull behaviour. This checks all four:
#
#   1. claude-pods/ and desloppify-pod/ are kustomizations listing every
#      top-level manifest (an unlisted one is simply not deployed).
#   2. Every ref to our own images in those two directories is
#      IfNotPresent. (codex-pods/ also runs claude-pod and is not
#      enrolled; it keeps its own pull story.)
#   3. Each Application carries the updater annotations, including the
#      pull secret, and the updater is granted that secret.
#   4. The root app-of-apps leaves /spec/source/kustomize alone.
#
# The reasoning lives next to each piece: claude-pods/kustomization.yaml,
# app-of-apps/apps/claude-pods.yaml, claude-pods/rbac.yaml and
# app-of-apps/app-of-apps.yaml.
#
# Run: claude-pods/tests/image-pinning.sh
set -uo pipefail
shopt -s nullglob

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
failed=0

fail() {
  echo "FAIL: $*"
  failed=1
}

registry=ghcr.io/christopherscot
# Both images are private and share one pull secret; the Applications
# name it and the RBAC grant below must land in the same namespace.
pull_secret_ns=claude-pods
pull_secret=ghcr-pull
# dir  alias (also the image name under $registry)  app-file
apps=(
  "claude-pods claude-pod app-of-apps/apps/claude-pods.yaml"
  "desloppify-pod desloppify-pod app-of-apps/apps/desloppify-pod.yaml"
)

for entry in "${apps[@]}"; do
  read -r dir alias app <<<"$entry"
  kz="$repo/$dir/kustomization.yaml"
  app="$repo/$app"
  image="$registry/$alias"

  # 1. A kustomization that enumerates every top-level manifest.
  [ -f "$kz" ] || { fail "$dir/kustomization.yaml is missing"; continue; }
  for f in "$repo/$dir"/*.yaml "$repo/$dir"/*.yml; do
    name=$(basename "$f")
    [ "$name" = kustomization.yaml ] && continue
    yq -e ".resources[] | select(. == \"$name\")" "$kz" >/dev/null 2>&1 ||
      fail "$dir/kustomization.yaml does not list $name - it will not be deployed"
  done
  rendered=$(kubectl kustomize "$repo/$dir") || { fail "$dir does not render"; continue; }

  # The kustomization and the Application must name the same image.
  yq -e ".images[] | select(.name == \"$image\")" "$kz" >/dev/null 2>&1 ||
    fail "$dir/kustomization.yaml has no images: entry for $image"
  image_list=$(yq '.metadata.annotations["argocd-image-updater.argoproj.io/image-list"]' "$app")
  [ "$image_list" = "$alias=$image:latest" ] ||
    fail "$app image-list is '$image_list', expected $alias=$image:latest"

  # 2. IfNotPresent at every ref, and every own-registry ref is the one
  #    image this Application's image-list enrols, at the tag git says
  #    (the digest is substituted on the live Application, never in CI).
  #    A second own image here would be IfNotPresent with no digest
  #    behind it and never update. Sidecars from other registries keep
  #    whatever policy they have.
  refs=$(printf '%s\n' "$rendered" |
    yq -N '.. | select(type == "!!map" and has("image") and has("name")) | .image + " " + (.imagePullPolicy // "<unset>")' |
    grep -F "$registry/" | sort -u)
  [ -n "$refs" ] || fail "$dir renders no reference to $registry images"
  while read -r ref policy; do
    [ "$ref" = "$image:latest" ] ||
      fail "$dir renders $ref, but only $image:latest is enrolled with the updater; an unenrolled own image on IfNotPresent never updates"
    [ "$policy" = IfNotPresent ] || fail "$dir: $ref has imagePullPolicy $policy, expected IfNotPresent"
  done <<<"$refs"

  # 3. Updater annotations on the Application.
  for kv in \
    "$alias.update-strategy=digest" \
    "$alias.pull-secret=pullsecret:$pull_secret_ns/$pull_secret" \
    "write-back-method=argocd"; do
    key="argocd-image-updater.argoproj.io/${kv%%=*}"
    want=${kv#*=}
    got=$(yq ".metadata.annotations[\"$key\"]" "$app")
    [ "$got" = "$want" ] || fail "$app: annotation $key is '$got', expected '$want'"
  done
done

# 3b. The updater's own RBAC stops at the argocd namespace, so the grant
#     must sit in the pull secret's namespace. rbac.yaml is deployed
#     (step 1 lists it).
rbac="$repo/claude-pods/rbac.yaml"
yq -e "select(.kind == \"Role\" and .metadata.name == \"image-updater-pull-secret\" and .metadata.namespace == \"$pull_secret_ns\")
  | .rules[] | select(.resourceNames[] == \"$pull_secret\" and .verbs[] == \"get\")" "$rbac" >/dev/null 2>&1 ||
  fail "$rbac: no Role image-updater-pull-secret in $pull_secret_ns granting get on secret $pull_secret"
yq -e "select(.kind == \"RoleBinding\" and .roleRef.name == \"image-updater-pull-secret\" and .metadata.namespace == \"$pull_secret_ns\")
  | .subjects[] | select(.kind == \"ServiceAccount\" and .name == \"argocd-image-updater\" and .namespace == \"argocd\")" "$rbac" >/dev/null 2>&1 ||
  fail "$rbac: Role image-updater-pull-secret is not bound to argocd:argocd-image-updater in $pull_secret_ns"

# 4. The root app leaves /spec/source/kustomize to the updater.
root="$repo/app-of-apps/app-of-apps.yaml"
yq -e '.spec.ignoreDifferences[]
  | select(.group == "argoproj.io" and .kind == "Application")
  | .jsonPointers[] | select(. == "/spec/source/kustomize")' "$root" >/dev/null 2>&1 ||
  fail "$root does not ignore /spec/source/kustomize on child Applications; selfHeal will revert every digest"
yq -e '.spec.syncPolicy.syncOptions[] | select(. == "RespectIgnoreDifferences=true")' "$root" >/dev/null 2>&1 ||
  fail "$root lacks RespectIgnoreDifferences=true; the ignore applies to diffs but not to syncs"

[ "$failed" -eq 0 ] && echo "PASS - both apps digest-pinned, IfNotPresent at every ref, updater can read the pull secret, root app leaves the digest alone"
exit "$failed"
