#!/usr/bin/env bash
set -euo pipefail
umask 077

# This pod uses the ChatGPT plan even if an API key is accidentally inherited.
unset OPENAI_API_KEY CODEX_API_KEY OPENAI_BASE_URL
export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CODEX_HOME"
cp /etc/codex-pod/config.toml "$CODEX_HOME/config.toml"

# Seed once. Codex refreshes this writable copy on the home PVC; recopying the
# immutable seed at each boot would roll back refreshed OAuth credentials.
if [ ! -e "$CODEX_HOME/auth.json" ]; then
  install -m 600 /run/secrets/codex/auth.json "$CODEX_HOME/auth.json"
fi
jq -e '.auth_mode == "chatgpt" and (.tokens.access_token | length > 0)
  and (.tokens.refresh_token | length > 0) and (.OPENAI_API_KEY == null)' \
  "$CODEX_HOME/auth.json" >/dev/null || {
  echo "FATAL: expected a cached ChatGPT login, not an API key" >&2
  exit 1
}
codex --version
codex login status

# Persist gh authentication so later non-interactive execs work as well.
gh auth login --hostname github.com --with-token < /run/secrets/git/token
gh auth setup-git --hostname github.com
gh api repos/ChristopherScot/homelab --jq '"GitHub repository access: " + .full_name'
if [ ! -d /workspace/homelab/.git ]; then
  git clone https://github.com/ChristopherScot/homelab.git /workspace/homelab
fi

# A real response, rather than login-status alone, proves subscription auth.
# Run outside the repo so no repository instructions or tasks are executed.
timeout --kill-after=15s 180s codex exec --cd /tmp --skip-git-repo-check \
  --ephemeral --sandbox read-only --output-last-message "$CODEX_HOME/startup-check.txt" \
  'Reply with exactly CODEX_POD_OK. Do not use tools or access any files.'
grep -qx 'CODEX_POD_OK' "$CODEX_HOME/startup-check.txt"
touch /tmp/codex-ready
echo 'Codex ready: ChatGPT login verified; repository cloned; waiting for instructions.'
exec sleep infinity
