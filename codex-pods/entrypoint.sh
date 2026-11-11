#!/usr/bin/env bash
set -euo pipefail
umask 077

# This pod uses the ChatGPT plan even if an API key is accidentally inherited.
unset OPENAI_API_KEY CODEX_API_KEY OPENAI_BASE_URL
export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CODEX_HOME"
if [ "$#" -eq 0 ]; then
  echo 'FATAL: a worker command is required' >&2
  exit 64
fi
# Shared across scheduled/manual pods. Hold through startup, authentication,
# repairs and reviews, not just the task, so concurrent Jobs cannot corrupt
# the writable login cache or shared checkout.
exec 8>"$CODEX_HOME/worker.lock"
if ! flock -n 8; then
  echo 'Another Codex worker owns the shared workspace; refusing this run.' >&2
  exit 75
fi

# Executables belong to the image, not the writable home PVC. Fail fast on
# an incorrect image; never install or update tools during worker startup.
CODEX_VERSION="${CODEX_VERSION:-0.167.0}"
export PATH="/opt/codex/node_modules/.bin:$PATH"
if ! { [ -x /opt/codex/node_modules/.bin/codex ] \
  && codex --version 2>/dev/null | grep -qx "codex-cli $CODEX_VERSION"; }; then
  echo "FATAL: worker image must contain Codex CLI $CODEX_VERSION under /opt/codex" >&2
  exit 1
fi
cp /etc/codex-pod/config.toml "$CODEX_HOME/config.toml"

# Use the workspace's automation token directly. Never fall back to the
# obsolete laptop OAuth cache or silently switch to Platform API billing.
if [ -z "${CODEX_ACCESS_TOKEN:-}" ]; then
  echo 'FATAL: CODEX_ACCESS_TOKEN must come from the Vault-backed worker secret' >&2
  exit 1
fi
codex --version
codex login status

# Persist gh authentication so later non-interactive execs work as well.
gh auth login --hostname github.com --with-token < /run/secrets/git/token
gh auth setup-git --hostname github.com
gh api repos/ChristopherScot/homelab --jq '"GitHub repository access: " + .full_name'
if [ ! -d /workspace/homelab/.git ]; then
  git clone https://github.com/ChristopherScot/homelab.git /workspace/homelab
fi

# Prove both subscription auth and shell execution inside this container.
# A chat-only probe previously passed while every real task failed to start
# Bubblewrap. Run outside the repo; no repository instructions/tasks are used.
timeout --kill-after=15s 180s codex exec --cd /tmp --skip-git-repo-check \
  --ephemeral --sandbox danger-full-access -c 'approval_policy="never"' --json \
  --output-last-message "$CODEX_HOME/startup-check.txt" \
  'Use the shell tool to run exactly: printf CODEX_POD_TOOL_OK. Only after it succeeds, reply with exactly CODEX_POD_OK. Do not access files or run any other command.' \
  | tee "$CODEX_HOME/startup-check.jsonl"
jq -se -f /etc/codex-pod/startup-check.jq "$CODEX_HOME/startup-check.jsonl" >/dev/null
grep -qx 'CODEX_POD_OK' "$CODEX_HOME/startup-check.txt"
touch /tmp/codex-ready
echo 'Codex worker ready: workspace access token and shell execution verified; starting task.'
exec "$@"
