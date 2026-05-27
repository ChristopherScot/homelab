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

# Start dir: explicit 2nd arg (a path under /workspace like "infra", or an
# absolute path) — sets where nvim/claude open, so claude loads that repo's
# .mcp.json / CLAUDE.md. A bare name is resolved under /workspace. If omitted,
# uses the pod's primary repo (/workspace/.primary-repo), else /workspace.
if [ -n "$START_DIR" ]; then
  case "$START_DIR" in
    /*) ;;                              # absolute, leave as-is
    *)  START_DIR="/workspace/$START_DIR" ;;  # relative -> under /workspace
  esac
elif [ -f /workspace/.primary-repo ]; then
  START_DIR=$(cat /workspace/.primary-repo)
fi
[ -n "$START_DIR" ] && [ -d "$START_DIR" ] || START_DIR=/workspace

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  # The work claude pane runs `claude --remote-control` so THIS session is also
  # reachable from claude.ai/code + phone WHILE you're working in it (bonus
  # remote access to your live dev session). Note: an attached interactive RC
  # session dies on SIGHUP when you close the terminal — so for durable,
  # always-on phone access the pod ALSO runs a dedicated never-attached `rc`
  # session (entrypoint). work = live session (remote bonus); rc = persistent.
  # RC name (in the claude.ai/code list): explicit name if given, else the
  # start dir's basename (e.g. "app", "infra") so it's identifiable.
  if [ -n "$NAME" ]; then rc_name="$NAME"; else rc_name="$(basename "$START_DIR")"; fi
  # left: nvim | right-top: claude --remote-control | right-bottom: shell.
  tmux new-session    -d -s "$SESSION" -n code -c "$START_DIR" "nvim .; exec zsh"
  tmux split-window -h -p 40 -t "$SESSION:code"   -c "$START_DIR" "claude --remote-control \"$rc_name\"; exec zsh"
  tmux split-window -v -p 40 -t "$SESSION:code.1" -c "$START_DIR"
  tmux select-pane -t "$SESSION:code.1"
fi

exec tmux attach -t "$SESSION"
