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
# This is the Job's main process, so stdout/stderr already reach container
# logs and Loki. Do not tee back into PID 1's own output pipe.
unset OPENAI_API_KEY CODEX_API_KEY OPENAI_BASE_URL
exec timeout --kill-after=30s 21600s node /etc/codex-pod/dependabot.mjs "$@"
