#!/usr/bin/env bash
# tmux-sessionizer (Primeagen-style, adapted for the claude pods).
# fzf-pick a repo/dir under /workspace and switch to a tmux session for it,
# creating the session (named after the dir) if it doesn't exist. Bound to
# <prefix>f in ~/.tmux.conf.
set -u

if [ "$#" -eq 1 ]; then
  selected="$1"
else
  # candidate dirs: top-level entries under /workspace (the repos)
  selected=$(find /workspace -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | fzf --prompt="workspace> ")
fi
[ -z "$selected" ] && exit 0

name=$(basename "$selected" | tr ' .:' '___')

# create the session detached if missing
if ! tmux has-session -t "$name" 2>/dev/null; then
  tmux new-session -d -s "$name" -c "$selected"
fi

# switch (inside tmux) or attach (outside tmux)
if [ -n "${TMUX:-}" ]; then
  tmux switch-client -t "$name"
else
  tmux attach -t "$name"
fi
