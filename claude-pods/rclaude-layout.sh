#!/usr/bin/env bash
# In-pod tmux work layout for hands-on editing + chatting with Claude.
# Invoked by the `rclaude N` wrapper on the Mac (ssh -> kubectl exec -> this).
# Idempotent: creates the "work" session once, then attaches; re-running just
# re-attaches. Separate from the "claude" session that runs the persistent
# Remote Control server (phone access) — so they don't collide.
#
# Layout (session "work"):
#   window 0 "code"  — left: neovim   | right(top): claude   right(bottom): shell
set -u

SESSION=work
# --build-only: create the session WITHOUT attaching (used by the pod
# entrypoint, which has no TTY). Otherwise build (if missing) + attach.
BUILD_ONLY=0
START_DIR=""
for a in "$@"; do
  case "$a" in
    --build-only) BUILD_ONLY=1 ;;
    *) START_DIR="$a" ;;
  esac
done
# Start in the pod's primary repo (first CLONE_REPOS entry, recorded by the
# entrypoint to /workspace/.primary-repo). Falls back to an explicit arg,
# then /workspace.
if [ -z "$START_DIR" ] && [ -f /workspace/.primary-repo ]; then
  START_DIR=$(cat /workspace/.primary-repo)
fi
[ -n "$START_DIR" ] && [ -d "$START_DIR" ] || START_DIR=/workspace

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  # window 0: neovim (left pane)
  tmux new-session -d -s "$SESSION" -n code -c "$START_DIR"
  tmux send-keys -t "$SESSION:code" 'nvim .' C-m

  # split right (40% width) for claude
  tmux split-window -h -p 40 -t "$SESSION:code" -c "$START_DIR"
  tmux send-keys -t "$SESSION:code.1" 'claude' C-m

  # split that right column bottom for a plain shell
  tmux split-window -v -p 40 -t "$SESSION:code.1" -c "$START_DIR"
  # (bottom pane left as a shell prompt)

  # focus the claude pane by default
  tmux select-pane -t "$SESSION:code.1"
fi

# entrypoint just wants the session built; interactive use attaches.
[ "$BUILD_ONLY" -eq 1 ] && exit 0
exec tmux attach -t "$SESSION"
