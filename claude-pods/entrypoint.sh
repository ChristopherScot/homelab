#!/usr/bin/env bash
# Boot orchestration for the Claude pods. Baked into the image and run as the
# container command (see Dockerfile / statefulset.yaml). Sets up the persistent
# home, secrets, repos, tmux plugins, and the always-on Remote Control session,
# then idles. Edit + rebuild the image to change boot behavior.
set +e

# $HOME (/home/node) is mounted on the persistent PVC, so the image's baked
# dotfiles (oh-my-zsh, nvim config, .zshrc) are shadowed on first boot. Seed
# them from the image's pristine copy (/opt/home-skel) if this is a fresh/empty
# home, so they persist AND stay user-editable. Marker file = already seeded.
if [ ! -f "$HOME/.home-seeded" ]; then
  cp -an /opt/home-skel/. "$HOME/" 2>/dev/null
  touch "$HOME/.home-seeded"
fi
# Image-managed config files always track the image (not frozen at first-seed):
# a stale persisted .tmux.conf with continuum auto-restore once kept
# resurrecting dead rc/work sessions and broke RC auto-start. Re-sync these on
# every boot. (User-editable state like nvim plugins, shell history, repos is
# NOT touched; user shell customization belongs in $ZSH_CUSTOM, also untouched.)
cp -f /opt/home-skel/.tmux.conf "$HOME/.tmux.conf" 2>/dev/null || true
cp -f /opt/home-skel/.zshrc     "$HOME/.zshrc"     2>/dev/null || true
git config --global credential.helper store
cp /run/secrets/git/.git-credentials "$HOME/.git-credentials" 2>/dev/null || true
chmod 600 "$HOME/.git-credentials" 2>/dev/null || true

# GCP auth: if the deploy key is mounted, activate it so gcloud is ready for
# ephemeral deploys on boot. Raw JSON (no base64).
if [ -f /run/secrets/gcp/key.json ]; then
  gcloud auth activate-service-account --key-file=/run/secrets/gcp/key.json --quiet 2>/dev/null \
    && gcloud config set project "$(cat /run/secrets/gcp/project 2>/dev/null)" --quiet 2>/dev/null \
    && gcloud auth configure-docker us-central1-docker.pkg.dev --quiet 2>/dev/null \
    && echo "gcloud authed for deploy" || echo "WARN: gcloud auth failed"
fi

# Per-pod repos by StatefulSet ordinal, read from a Vault-backed secret file
# (/run/secrets/repos/pod<ordinal>) so specific repo names aren't committed to
# this repo. Falls back to CLONE_REPOS.
ORD="${HOSTNAME##*-}"
REPOS="$(cat "/run/secrets/repos/pod${ORD}" 2>/dev/null || echo "${CLONE_REPOS:-}")"
echo "pod ordinal=$ORD -> $(echo "$REPOS" | wc -w) repo(s)"
# space/comma/newline-separated; full URLs or owner/repo slugs (assumed
# github.com). Idempotent: skips a repo dir that exists.
primary=""
for r in $(echo "${REPOS:-}" | tr ',\n' '  '); do
  [ -z "$r" ] && continue
  case "$r" in
    http*://*|git@*) url="$r" ;;
    */*)             url="https://github.com/$r.git" ;;
    *)               echo "skip unrecognized repo ref: $r"; continue ;;
  esac
  dir="/workspace/$(basename "$r" .git)"
  [ -z "$primary" ] && primary="$dir"   # first repo = primary
  if [ -d "$dir/.git" ]; then
    echo "repo present: $dir"
  else
    echo "cloning $url -> $dir"
    git clone "$url" "$dir" || echo "WARN: clone failed: $url"
  fi
done
# record the primary repo dir so `rclaude` opens there by default
[ -n "$primary" ] && echo "$primary" > /workspace/.primary-repo

# Install tmux plugins (resurrect/continuum) via tpm if missing.
# tpm install needs a running tmux server with the conf sourced.
if [ -d "$HOME/.tmux/plugins/tpm" ] && [ ! -d "$HOME/.tmux/plugins/tmux-resurrect" ]; then
  tmux new-session -d -s _tpm 2>/dev/null
  tmux source-file "$HOME/.tmux.conf" 2>/dev/null
  "$HOME/.tmux/plugins/tpm/bin/install_plugins" >/dev/null 2>&1 || true
  tmux kill-session -t _tpm 2>/dev/null
fi

# Clear orphaned nvim swap files. Panes/sessions killed (not :q'd) leave swap
# files behind, so opening a file later triggers nvim's E325 "swap already
# exists" recovery prompt — the annoying split-looking dialog. At boot no nvim
# is running yet, so every swap file in this dir is by definition an orphan.
rm -f "$HOME"/.local/state/nvim/swap/*.sw[a-p] 2>/dev/null || true

# Always-on Remote Control, the way that actually survives: run interactive
# `claude --remote-control` in a dedicated `rc` tmux session that we NEVER
# attach to. Why this works where the others didn't:
#   - server mode (`claude remote-control`) came up Capacity 0/32 headless
#     -> phone spun. Avoided.
#   - interactive RC inside an *attached* pane died on SIGHUP when you closed
#     the terminal -> phone lost it. Avoided: nothing ever attaches to `rc`,
#     so there's no terminal to close and no HUP; tmux holds the pty, claude
#     stays up + connectable.
tmux kill-server 2>/dev/null
tmux start-server 2>/dev/null
# Name it "<repo>-persistent <MM-DD HH:MM>" so it's distinct in the
# claude.ai/code list from the per-work-session RC envs ("<repo>" or "<name>"),
# and the boot timestamp makes the freshest one obvious after a roll (each roll
# spins up a new persistent RC; the latest timestamp is the live one).
RC_NAME="$(basename "$(cat /workspace/.primary-repo 2>/dev/null || echo workspace)")-persistent $(date '+%m-%d %H:%M')"
RC_DIR="$(cat /workspace/.primary-repo 2>/dev/null || echo /workspace)"
[ -d "$RC_DIR" ] || RC_DIR=/workspace
tmux new-session -d -s rc -c "$RC_DIR" \
  "while true; do claude --remote-control \"$RC_NAME\"; echo 'RC exited; restart 5s'; sleep 5; done"

# Always-on VS Code Tunnel — same survivor pattern as `rc` (detached tmux
# session, nothing ever attaches, restart loop). Connect from desktop VS Code
# (Remote Tunnels extension) or vscode.dev/tunnel/<name>. Tunnel name is per-
# pod so the two replicas don't collide in the GitHub-account namespace.
# First-boot login: `tmux attach -t vscode`, copy the device-code URL/code,
# complete the GitHub login, then `Ctrl-b d` to detach. Login persists under
# $HOME/.vscode-cli (PVC), so subsequent restarts come up authed.
TUNNEL_NAME="claude-${OWNER:-pod}-${ORD}"
tmux new-session -d -s vscode -c "$RC_DIR" \
  "while true; do code tunnel --accept-server-license-terms --name \"$TUNNEL_NAME\"; echo 'tunnel exited; restart 5s'; sleep 5; done"

# The `work` layout (nvim + claude + shell) is built by `rclaude N` on attach
# (needs a real TTY). It's separate from the `rc` session above. Run
# `rclaude N` from any machine to start/attach work.
exec sleep infinity
