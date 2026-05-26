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

# Start dir: explicit 2nd arg, else the pod's primary repo (recorded by the
# entrypoint to /workspace/.primary-repo) so claude picks up that repo's
# project config (.mcp.json, CLAUDE.md). Falls back to /workspace.
# To work in a different repo (e.g. infra) with ITS config, use the tmux
# sessionizer: <prefix>f -> fzf-pick the repo -> its own session.
if [ -z "$START_DIR" ] && [ -f /workspace/.primary-repo ]; then
  START_DIR=$(cat /workspace/.primary-repo)
fi
[ -n "$START_DIR" ] && [ -d "$START_DIR" ] || START_DIR=/workspace

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  # left: nvim | right-top: claude | right-bottom: shell.
  tmux new-session    -d -s "$SESSION" -n code -c "$START_DIR" "nvim .; exec zsh"
  tmux split-window -h -p 40 -t "$SESSION:code"   -c "$START_DIR" "claude; exec zsh"
  tmux split-window -v -p 40 -t "$SESSION:code.1" -c "$START_DIR"
  tmux select-pane -t "$SESSION:code.1"
fi

exec tmux attach -t "$SESSION"
