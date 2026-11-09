#!/usr/bin/env bash
# The trigger manifest must use a pullable image and no shell wrapper.
#
# Both facts are already recorded in claude-pods/nightly-cronjobs.yaml,
# and this manifest reintroduced both by being written from an older
# copy: bitnami/kubectl is gone from Docker Hub, so the job sat in
# ErrImagePull for three nights and reported DeadlineExceeded; and the
# registry.k8s.io image's entrypoint is kubectl with no shell, so an
# `sh -c` form exits 128 before running anything.
set -uo pipefail
fail=0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$here/desloppify-cronjob.yaml"

if grep -q "bitnami" "$manifest"; then
  if grep -qE '^\s+image:.*bitnami' "$manifest"; then
    echo "FAIL: uses a bitnami image - deleted from Docker Hub, will not pull"
    fail=1
  fi
fi

grep -qE '^\s+image: registry\.k8s\.io/kubectl:' "$manifest" || {
  echo "FAIL: the trigger does not use registry.k8s.io/kubectl"; fail=1; }

# The kubectl image ships no shell.
if grep -qE '^\s+command:' "$manifest"; then
  if grep -qE '^\s+- (/bin/)?(sh|bash)$' "$manifest"; then
    echo "FAIL: wraps the trigger in a shell; this image has none (exits 128)"
    fail=1
  fi
fi

# It must still reach the right pod and script.
grep -q "desloppify-0" "$manifest" || { echo "FAIL: does not name desloppify-0"; fail=1; }
grep -q "nightly-desloppify.sh" "$manifest" || { echo "FAIL: does not invoke the runner"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS - pullable image, no shell wrapper, targets the right pod and script"
exit "$fail"
