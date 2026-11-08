#!/usr/bin/env bash
# The runner must find its own tools without inheriting a helpful PATH.
#
# The image sets PATH so the venv comes first, but that applies to the
# container's main process. `kubectl exec` builds its own environment and
# the CronJob's `env VAR=... script` form does not restore it, so three
# runs exited at the PATH check with a preflight log and an empty report.
set -uo pipefail
fail=0
script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nightly-desloppify.sh"

# The runner must set PATH itself rather than trusting the caller's.
if ! grep -q '^export PATH="\$DESLOPPIFY_VENV/bin:\$PATH"' "$script"; then
  echo "FAIL: the runner does not put its venv on PATH"
  fail=1
fi

# That has to happen before anything calls desloppify.
path_line=$(grep -n '^export PATH=' "$script" | head -1 | cut -d: -f1)
first_use=$(grep -n 'command -v desloppify\|desloppify update-skill' "$script" | head -1 | cut -d: -f1)
if [ -n "$path_line" ] && [ -n "$first_use" ] && [ "$path_line" -gt "$first_use" ]; then
  echo "FAIL: PATH is set at line $path_line, after desloppify is used at $first_use"
  fail=1
fi

# A FATAL here must say what it looked for; the first one did not, and
# the run that hit it left no way to tell why.
if ! grep -q 'expected it at .DESLOPPIFY_VENV' "$script"; then
  echo "FAIL: the PATH failure does not name the path it expected"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS - runner sets its own PATH, before use, and explains a miss"
exit "$fail"
