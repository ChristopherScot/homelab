#!/usr/bin/env bash
# The mount check refuses an unwritable workspace and accepts a good one.
#
# A faulted Longhorn volume answers with EIO rather than disappearing, so
# `[ -d ... ]` alone passes on a dead mount. The probe must actually
# write.
set -uo pipefail
fail=0
tmp=$(mktemp -d); trap 'chmod u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

# Same function the runner uses.
workspace_ok() {
  local probe="${WORK_ROOT}/.mount-probe.$$"
  [ -d "$WORK_ROOT" ] || return 1
  touch "$probe" 2>/dev/null || return 1
  rm -f "$probe" 2>/dev/null || return 1
  return 0
}

WORK_ROOT="$tmp"
workspace_ok || { echo "FAIL: a writable dir was rejected"; fail=1; }

WORK_ROOT="$tmp/does-not-exist"
workspace_ok && { echo "FAIL: a missing dir was accepted"; fail=1; }

# Unwritable but present - the shape a faulted mount takes.
mkdir -p "$tmp/ro" && chmod a-w "$tmp/ro"
WORK_ROOT="$tmp/ro"
if [ "$(id -u)" = "0" ]; then
  echo "  (skipping read-only case: root ignores mode bits)"
else
  workspace_ok && { echo "FAIL: an unwritable dir was accepted"; fail=1; }
fi
chmod u+w "$tmp/ro"

# A file where the directory should be.
touch "$tmp/afile"; WORK_ROOT="$tmp/afile"
workspace_ok && { echo "FAIL: a plain file was accepted as the workspace"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS - mount check accepts a writable dir, refuses missing, unwritable and non-dir"
exit "$fail"
