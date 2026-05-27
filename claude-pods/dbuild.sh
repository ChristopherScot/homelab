#!/usr/bin/env bash
# Rootless in-pod image build + push. Wraps buildctl/buildkitd (started under
# rootlesskit on demand) so you can build images from these pods — primarily to
# rebuild the claude-pod image itself and other Dockerfiles — without a Docker
# daemon, Docker-in-Docker, or a privileged container.
#
# Usage:
#   dbuild <image-ref> [context-dir] [-- <buildctl frontend opts>]
#     dbuild ghcr.io/christopherscot/claude-pod:latest .
#     dbuild ghcr.io/me/app:dev ./app --opt build-arg:FOO=bar
#
# Push is on by default (the point is producing a registry artifact). The
# resulting ref can then be deployed (e.g. `dp <tag>`).
#
# Registry auth: reuses the GitHub token already on the pod (~/.git-credentials,
# wired by the entrypoint) for ghcr.io. For other registries, log in first so
# ~/.docker/config.json has an entry (e.g. `gcloud auth configure-docker`,
# already run by the entrypoint for us-central1-docker.pkg.dev).
set -euo pipefail

IMAGE="${1:?usage: dbuild <image-ref> [context-dir] [-- buildctl opts]}"
shift
CONTEXT="."
if [ "${1:-}" != "" ] && [ "${1:-}" != "--" ]; then CONTEXT="$1"; shift; fi
[ "${1:-}" = "--" ] && shift

DOCKERFILE="${CONTEXT}/Dockerfile"
[ -f "$DOCKERFILE" ] || { echo "dbuild: no Dockerfile at $DOCKERFILE" >&2; exit 1; }

# Derive a ghcr.io docker auth entry from the pod's GitHub token if we don't
# already have one. buildctl reads ~/.docker/config.json for push creds.
mkdir -p "$HOME/.docker"
if ! grep -q "ghcr.io" "$HOME/.docker/config.json" 2>/dev/null; then
  tok="$(sed -n 's#https://\([^:]*\):\([^@]*\)@github.com#\2#p' "$HOME/.git-credentials" 2>/dev/null | head -1)"
  usr="$(sed -n 's#https://\([^:]*\):\([^@]*\)@github.com#\1#p' "$HOME/.git-credentials" 2>/dev/null | head -1)"
  if [ -n "$tok" ]; then
    auth="$(printf '%s:%s' "${usr:-x}" "$tok" | base64 -w0)"
    node -e '
      const fs=require("fs"), p=process.env.HOME+"/.docker/config.json";
      let c={}; try{c=JSON.parse(fs.readFileSync(p))}catch{}
      c.auths=c.auths||{}; c.auths["ghcr.io"]={auth:process.env.AUTH};
      fs.writeFileSync(p, JSON.stringify(c,null,2));
    ' AUTH="$auth" 2>/dev/null || true
  fi
fi

# Start a rootless buildkitd if one isn't already up on our socket.
SOCK="unix://${XDG_RUNTIME_DIR:-/tmp}/buildkit-${UID}.sock"
ROOT="${XDG_RUNTIME_DIR:-/tmp}/buildkit-${UID}-root"
if ! buildctl --addr "$SOCK" debug workers >/dev/null 2>&1; then
  echo "dbuild: starting rootless buildkitd…"
  rootlesskit buildkitd --oci-worker-rootless --root "$ROOT" --addr "$SOCK" \
    >"${XDG_RUNTIME_DIR:-/tmp}/buildkitd.log" 2>&1 &
  for _ in $(seq 1 20); do
    buildctl --addr "$SOCK" debug workers >/dev/null 2>&1 && break
    sleep 0.5
  done
  buildctl --addr "$SOCK" debug workers >/dev/null 2>&1 || {
    echo "dbuild: buildkitd failed to start; log:" >&2
    tail -20 "${XDG_RUNTIME_DIR:-/tmp}/buildkitd.log" >&2
    exit 1
  }
fi

echo "dbuild: building $IMAGE from $CONTEXT (push)…"
exec buildctl --addr "$SOCK" build \
  --frontend dockerfile.v0 \
  --local context="$CONTEXT" \
  --local dockerfile="$CONTEXT" \
  --output "type=image,name=${IMAGE},push=true" \
  "$@"
