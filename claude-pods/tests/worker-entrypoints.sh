#!/usr/bin/env bash
# Entrypoints must preserve dispatcher arguments and propagate worker failure.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/kaneo-worker" <<'WORKER'
#!/bin/sh
printf '%s\n' "$@" > "$CAPTURE"
exit 17
WORKER
chmod +x "$tmp/kaneo-worker"
for stage in author test merge; do
  rc=0
  PATH="$tmp:$PATH" CAPTURE="$tmp/args" bash "$here/stage-$stage.sh" 'task id' owner/repo cmd1 || rc=$?
  [ "$rc" = 17 ]
  printf '%s\n' "$stage" 'task id' owner/repo cmd1 > "$tmp/want"
  diff -u "$tmp/want" "$tmp/args"
done
echo 'PASS: thin worker entrypoints preserve arguments and failure'
