#!/usr/bin/env bash
# Shell helpers for the in-cluster Claude Code pods (claude-pods namespace).
#
# ── INSTALL (per machine) ───────────────────────────────────────────────────
#   1. Clone the homelab repo to ~/homelab (or anywhere; adjust the path below):
#        git clone https://github.com/ChristopherScot/homelab ~/homelab
#
#   2. Source this file from your shell rc (~/.zshrc or ~/.bashrc):
#        echo 'source "$HOME/homelab/scripts/claude-pods.sh"' >> ~/.zshrc
#        source ~/.zshrc            # or open a new terminal
#
#   3. Make sure `ssh homelab` works (these commands hop through it for kubectl).
#      Add to ~/.ssh/config if needed, e.g.:
#        Host homelab
#          HostName pop-os            # tailnet name / IP of a cluster host
#          User <you>
#      Test:  ssh homelab kubectl get nodes
#
# ── COMMANDS ────────────────────────────────────────────────────────────────
#   rclaude [0|1]      open the tmux WORK layout (neovim + claude + shell)
#   rclaude-sh [0|1]   plain shell in the pod
#
# Remote Control (phone/web access) runs automatically in each pod's `rc`
# session — drive it from claude.ai/code or the Claude app. There's no terminal
# command for it: attaching the rc session only shows the server's status
# screen, not a joinable conversation, so it isn't exposed here.
#
# Pods: claude-session-0 (homelab repo), claude-session-1 (schoolhouse app+infra).
# ─────────────────────────────────────────────────────────────────────────────

# rclaude N [name] [dir] — open a tmux WORK layout (neovim + claude + shell) in pod N.
#   rclaude               -> pod 0, default "work" session, primary repo
#   rclaude 1             -> pod 1, default "work" session, primary repo
#   rclaude 1 feat-x      -> pod 1, independent "work-feat-x" session
#   rclaude 1 infra infra -> pod 1, "work-infra" session started in /workspace/infra
# <dir> may be a path under /workspace (e.g. "infra") or absolute; it sets
# where nvim/claude open (so claude loads that repo's .mcp.json / CLAUDE.md).
# Multiple names = parallel workspaces; re-running a name re-attaches.
# Inside tmux: <prefix>s switch sessions, <prefix>d detach, <prefix>f sessionizer.
rclaude() {
  local n="${1:-0}"
  local name="${2:-}"
  local dir="${3:-}"
  case "$n" in
    0|1) ;;
    *) echo "usage: rclaude [0|1] [session-name] [dir]" >&2; return 2 ;;
  esac
  ssh -t homelab kubectl exec -it -n claude-pods "claude-session-${n}" \
    -- /usr/local/bin/rclaude-layout "$name" "$dir"
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
