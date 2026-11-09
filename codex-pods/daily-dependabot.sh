#!/usr/bin/env bash
set -euo pipefail
umask 077
# The same lock will also be used by future Kaneo-dispatched Codex tasks.
# Acquire it inside the pod, so restarting a trigger cannot cause overlap.
exec 9>/tmp/codex-task.lock
if ! flock -n 9; then
  echo 'Codex is busy; daily Dependabot repair skipped.'
  exit 0
fi
# Exec output otherwise bypasses container logs and Loki. Keep both streams
# visible to the trigger and to the pod's normal log collector.
if [ -w /proc/1/fd/1 ]; then
  exec > >(tee /proc/1/fd/1) 2>&1
fi
unset OPENAI_API_KEY CODEX_API_KEY OPENAI_BASE_URL
exec timeout --kill-after=30s 21600s node /etc/codex-pod/dependabot.mjs "$@"
