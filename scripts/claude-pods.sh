#!/usr/bin/env bash
# Shell helpers for the in-cluster Claude Code pods (claude-pods namespace).
# Source this from your shell rc so the commands port across machines:
#
#   # in ~/.zshrc or ~/.bashrc:
#   source "$HOME/homelab/scripts/claude-pods.sh"
#
# Requires: ssh access to the `homelab` host (which has kubectl).
# Pods: claude-session-0 (homelab repo), claude-session-1 (schoolhouse app+infra).

# rclaude N — open the tmux WORK layout (neovim + claude + shell) in pod N.
#   rclaude        -> pod 0
#   rclaude 1      -> pod 1
rclaude() {
  local n="${1:-0}"
  case "$n" in
    0|1) ;;
    *) echo "usage: rclaude [0|1]" >&2; return 2 ;;
  esac
  ssh -t homelab kubectl exec -it -n claude-pods "claude-session-${n}" \
    -- /usr/local/bin/rclaude-layout
}

# rclaude-rc N — attach the persistent Remote Control tmux session (the one
# bridged to claude.ai/code + mobile), to watch/drive it from a terminal.
rclaude-rc() {
  local n="${1:-0}"
  case "$n" in
    0|1) ;;
    *) echo "usage: rclaude-rc [0|1]" >&2; return 2 ;;
  esac
  ssh -t homelab kubectl exec -it -n claude-pods "claude-session-${n}" \
    -- tmux attach -t claude
}

# rclaude-sh N — just drop into a plain shell in pod N (no tmux layout).
rclaude-sh() {
  local n="${1:-0}"
  case "$n" in
    0|1) ;;
    *) echo "usage: rclaude-sh [0|1]" >&2; return 2 ;;
  esac
  ssh -t homelab kubectl exec -it -n claude-pods "claude-session-${n}" -- zsh
}
