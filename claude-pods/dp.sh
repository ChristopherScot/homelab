#!/usr/bin/env bash
# `dp` — ergonomic wrapper around schoolhouse infra's deploy-ephemeral.sh.
# Deploys a webapp image tag to a Cloud Run ephemeral env.
#
#   dp <tag>                 -> deploy to your own env: webapp--$OWNER
#   dp <env-name> <tag>      -> deploy to an explicit env (e.g. staging-2)
#
# $OWNER is set per-pod (the engineer who owns it). The underlying script +
# gcloud auth (github-actions-deploy SA, shw-development) come from the pod.
set -euo pipefail

SCRIPT=/workspace/infra/scripts/deploy-ephemeral.sh
if [ ! -x "$SCRIPT" ]; then
  echo "dp: $SCRIPT not found (is the infra repo cloned?)" >&2
  exit 1
fi

case $# in
  1)
    # dp <tag> -> own env (webapp--$OWNER)
    if [ -z "${OWNER:-}" ]; then
      echo "dp: \$OWNER is unset; use 'dp <env-name> <tag>' or set OWNER." >&2
      exit 1
    fi
    exec "$SCRIPT" "webapp--${OWNER}" "$1"
    ;;
  2)
    # dp <env-name> <tag> -> explicit env (staging-2, webapp--max, ...)
    exec "$SCRIPT" "$1" "$2"
    ;;
  *)
    echo "usage: dp <tag>                 (-> webapp--\$OWNER)" >&2
    echo "       dp <env-name> <tag>      (-> explicit env, e.g. staging-2)" >&2
    exit 1
    ;;
esac
