#!/usr/bin/env bash
# The log redirection must not block.
#
# `exec > >(tee ...)` leaves the process substitution's stdin open with
# nothing to close it under `kubectl exec` without a TTY. The first
# scheduled run hung there and was killed on activeDeadlineSeconds three
# hours later, having written no log to explain itself.
set -uo pipefail
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

LOG="$tmp/run.log"
PID1="$tmp/pid1"           # stands in for /proc/1/fd/1
: > "$LOG"; : > "$PID1"

# The same shape the runner uses, in a child so EXIT fires.
run_once() {
  timeout 10 bash -c '
    LOG="$1"; PID1="$2"
    _log_start=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    exec >> "$LOG" 2>&1
    publish_log() {
      if [ -w "$PID1" ]; then
        tail -n "+$((_log_start + 1))" "$LOG" > "$PID1" 2>/dev/null || true
      fi
    }
    trap publish_log EXIT
    echo "$3"
  ' _ "$LOG" "$PID1" "$1"
}

run_once first
rc=$?
[ "$rc" -eq 124 ] && { echo "FAIL: the redirection hung - the bug that killed the first cron run"; exit 1; }
[ "$rc" -eq 0 ]   || { echo "FAIL: first run exited $rc"; fail=1; }
grep -q first "$LOG"  || { echo "FAIL: nothing reached the log file"; fail=1; }
grep -q first "$PID1" || { echo "FAIL: nothing reached pid 1"; fail=1; }

run_once second
[ "$?" -eq 0 ] || { echo "FAIL: second run did not exit cleanly"; fail=1; }
grep -q first  "$PID1" && { echo "FAIL: the second run republished the first run's output"; fail=1; }
grep -q second "$PID1" || { echo "FAIL: the second run's output did not reach pid 1"; fail=1; }
grep -q first  "$LOG"  || { echo "FAIL: the file lost the first run's output"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS - returns promptly, reaches the log and pid 1, and does not resend"
exit "$fail"
