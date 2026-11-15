#!/usr/bin/env bash
# Acceptance must follow lock acquisition, and an expired launch must stop.
set -euo pipefail
command -v flock >/dev/null || { echo 'SKIP: flock requires Linux'; exit 0; }
source "$(dirname "${BASH_SOURCE[0]}")/../lib/pod-common.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export NIGHTLY_LOCK="$tmp/lock"
export NIGHTLY_LAUNCH_ACK="$tmp/ack"
(
  take_pod_lock
  test "$(cat "$NIGHTLY_LAUNCH_ACK")" = accepted
  # Independent descriptor: a second worker must acknowledge contention.
  (
    exec 9>&-
    NIGHTLY_LAUNCH_ACK="$tmp/busy"
    if take_pod_lock; then echo 'second worker acquired occupied lock' >&2; exit 1; fi
    test "$(cat "$NIGHTLY_LAUNCH_ACK")" = busy
  )
)
(
  NIGHTLY_LAUNCH_ACK="$tmp/expired/ack"
  if take_pod_lock 2>/dev/null; then echo 'worker accepted an expired launch' >&2; exit 1; fi
)
# Existing/manual launch callers do not participate in the handshake.
(unset NIGHTLY_LAUNCH_ACK; take_pod_lock)
echo 'PASS: worker launch acknowledgment'
