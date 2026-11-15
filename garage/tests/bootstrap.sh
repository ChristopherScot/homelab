#!/usr/bin/env bash
# Exercise the actual bootstrap program with a stateful kubectl substitute.
set -euo pipefail
python3 "$(dirname "$0")/test_bootstrap.py"
