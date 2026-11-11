#!/usr/bin/env bash
# Run with --network=none and a fresh /home/node to prove cold CLI startup.
set -euo pipefail
expected_version="${CODEX_VERSION:-0.167.0}"
test "$(id -u)" = 1000
test -w "$HOME"
# A stale PVC install must not shadow the image's CLI.
mkdir -p "$HOME/.codex/tools/node_modules/.bin"
printf '#!/bin/sh\nexit 99\n' > "$HOME/.codex/tools/node_modules/.bin/codex"
chmod +x "$HOME/.codex/tools/node_modules/.bin/codex"
test "$(command -v codex)" = /opt/codex/node_modules/.bin/codex
codex --version | grep -qx "codex-cli $expected_version"
for tool in node npm corepack git gh jq bash flock timeout; do
  command -v "$tool" >/dev/null || { echo "Missing runtime tool: $tool" >&2; exit 1; }
done
printf 'Offline Codex image smoke test passed (%s).\n' "$expected_version"
