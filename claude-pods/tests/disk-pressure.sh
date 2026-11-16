#!/usr/bin/env bash
# Only known disk pressure should trigger the regenerable-cache cleanup.
# Process termination and lock lifetime are tested with the Go supervisor.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/df" <<'DF'
#!/bin/sh
[ "$TEST_PCT" != unknown ] || exit 1
printf 'Filesystem blocks used available capacity mount\n/dev/test 100 90 10 %s%% /home\n' "$TEST_PCT"
DF
cat > "$tmp/bin/go" <<'TOOL'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$PRUNE_LOG"
TOOL
cp "$tmp/bin/go" "$tmp/bin/npm"
chmod +x "$tmp/bin/df" "$tmp/bin/go" "$tmp/bin/npm"
export PATH="$tmp/bin:$PATH" PRUNE_LOG="$tmp/pruned"
for pct in 50 unknown 90; do
  : > "$PRUNE_LOG"
  TEST_PCT="$pct" HOME_TIGHT_PCT=85 bash "$here/lib/maintenance.sh" prune
  if [ "$pct" = 90 ]; then
    grep -q 'go clean -modcache' "$PRUNE_LOG"
    grep -q 'go clean -cache' "$PRUNE_LOG"
    grep -q 'npm cache clean --force' "$PRUNE_LOG"
  else
    [ ! -s "$PRUNE_LOG" ]
  fi
done
echo 'PASS: caches pruned only under observed disk pressure'
