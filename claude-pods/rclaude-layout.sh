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
# Start in the pod's primary repo (first CLONE_REPOS entry, recorded by the
# entrypoint to /workspace/.primary-repo). Falls back to an explicit arg,
# then /workspace.
START_DIR="${1:-}"
if [ -z "$START_DIR" ] && [ -f /workspace/.primary-repo ]; then
  START_DIR=$(cat /workspace/.primary-repo)
fi
[ -n "$START_DIR" ] && [ -d "$START_DIR" ] || START_DIR=/workspace

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  # Launch nvim + claude as each pane's COMMAND (not send-keys, which races
  # the shell's oh-my-zsh/starship startup and drops the keystrokes). Wrap as
  # 'prog; exec zsh' so quitting the program drops to a normal shell instead
  # of closing the pane. left: nvim | right-top: claude | right-bottom: shell.
  tmux new-session    -d -s "$SESSION" -n code -c "$START_DIR" "nvim .; exec zsh"
  tmux split-window -h -p 40 -t "$SESSION:code"   -c "$START_DIR" "claude; exec zsh"
  tmux split-window -v -p 40 -t "$SESSION:code.1" -c "$START_DIR"
  tmux select-pane -t "$SESSION:code.1"
fi

exec tmux attach -t "$SESSION"
