#!/bin/bash
# One-time installer that symlinks the tracked hooks into .git/hooks/.
# Re-run after cloning the repo on a new machine.
set -euo pipefail
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
for src in bootstrap/hooks/*; do
  name=$(basename "$src")
  ln -sf "../../$src" ".git/hooks/$name"
  chmod +x "$src"
  echo "installed .git/hooks/$name -> $src"
done
