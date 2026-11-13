#!/usr/bin/env bash
set -euo pipefail
node --test "$(dirname "$0")/reconcile-merged.test.mjs"
