#!/usr/bin/env bash
# PID 1 is the idle session process; kubectl-exec workers need an explicit
# signal. Prevent new commands, then wait for their lock through checkpoint
# (120s), reporting (30s), and process cleanup. /tmp resets with the container.
set -euo pipefail
lock="${NIGHTLY_LOCK:-/tmp/nightly.lock}"
touch "$lock.stopping"
rc=0
pkill -TERM -x kaneo-worker || rc=$?
# pkill returns 1 when the pod has no worker, which is normal when idle.
if [ "$rc" -gt 1 ]; then
  echo "could not signal worker (pkill exit $rc)" >&2
  exit "$rc"
fi
if ! flock -w 165 "$lock" true; then
  echo 'worker did not release its lock before the shutdown deadline' >&2
  exit 1
fi
