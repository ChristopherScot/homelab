#!/usr/bin/env bash
# In-pod tmux work layout for hands-on editing + chatting with Claude.
# Invoked by the `rclaude N [name]` wrapper on the Mac.
#
# Usage (inside the pod):
#   rclaude-layout                 -> session "work" (the default)
#   rclaude-layout <name>          -> session "work-<name>" (parallel workspace)
#   rclaude-layout <name> <dir>    -> ... starting in <dir>
#
# Each session is independent (own nvim + claude + shell), so you can run
# several for different tasks and switch between them. Idempotent: re-running
# with the same name re-attaches to that session.
#
# Layout per session "work[-name]" (window "code"):
#   left: neovim | right-top: claude | right-bottom: shell
set -u

NAME="${1:-}"
START_DIR="${2:-}"
if [ -n "$NAME" ]; then
  SESSION="work-${NAME}"
else
  SESSION="work"
fi

# Start dir: explicit 2nd arg, else the pod's primary repo (first CLONE_REPOS
# entry, recorded by the entrypoint to /workspace/.primary-repo), else /workspace.
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
