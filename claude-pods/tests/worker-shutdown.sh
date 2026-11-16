#!/usr/bin/env bash
# Exercise signal delivery and the real lock wait without signalling any
# unrelated local worker. The pkill shim targets only this test's child.
set -euo pipefail
if ! command -v flock >/dev/null; then
  echo 'SKIP: worker shutdown test requires Linux flock'
  exit 0
fi
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
worker_pid=''
hook_pid=''
cleanup() {
  touch "$tmp/release"
  [ -z "$worker_pid" ] || kill "$worker_pid" 2>/dev/null || true
  [ -z "$hook_pid" ] || kill "$hook_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
export NIGHTLY_LOCK="$tmp/worker.lock" SHUTDOWN_TEST_DIR="$tmp"
cat > "$tmp/pkill" <<'SHIM'
#!/bin/sh
[ "$*" = '-TERM -x kaneo-worker' ] || exit 2
kill -TERM "$SHUTDOWN_TEST_PID"
SHIM
chmod +x "$tmp/pkill"
bash -c '
  exec 9>"$NIGHTLY_LOCK"
  flock 9
  checkpoint() {
    touch "$SHUTDOWN_TEST_DIR/signalled"
    while [ ! -f "$SHUTDOWN_TEST_DIR/release" ]; do sleep 0.01; done
    touch "$SHUTDOWN_TEST_DIR/checkpoint"
    exit 0
  }
  trap checkpoint TERM
  touch "$SHUTDOWN_TEST_DIR/ready"
  while :; do sleep 0.1; done
' &
worker_pid=$!
export SHUTDOWN_TEST_PID="$worker_pid"
wait_file() {
  local i
  for ((i=0; i<500; i++)); do
    [ ! -f "$1" ] || return 0
    sleep 0.01
  done
  echo "timed out waiting for $1" >&2
  return 1
}
wait_file "$tmp/ready"
PATH="$tmp:$PATH" bash "$here/stop-worker.sh" &
hook_pid=$!
wait_file "$tmp/signalled"
[ -f "$NIGHTLY_LOCK.stopping" ]
kill -0 "$hook_pid" # preStop must remain alive while cleanup holds the lock
[ ! -f "$tmp/checkpoint" ]
touch "$tmp/release"
wait "$hook_pid"
hook_pid=''
wait "$worker_pid"
worker_pid=''
[ -f "$tmp/checkpoint" ]
echo 'PASS: shutdown signals the worker and waits for checkpoint lock release'
