#!/usr/bin/env bash
# Boot for the task-worker pod (task/Dockerfile). Clone this pod's repo
# list, make sure the agent's home has what the worker expects, then idle:
# the dispatcher execs stage-author/test/merge into the running container.
#
# A copy of the repo-clone and trust steps of ../entrypoint.sh, not a
# shared lib: lib/ and *.sh under claude-pods/ are session-image source,
# and touching them rolls that image. README.md schedules the merge. The
# interactive-only steps (shell/editor home, gh and gcloud login, tmux
# plugins, the Remote Control session) are left out; the Dockerfile's
# gitconfig comment says why no login step is needed here.
#
# TASK_WORKSPACE and TASK_SECRETS_DIR are seams for
# tests/task-entrypoint.sh; the pod sets neither. TASK_SKILLS_DIR is set
# by the image.
set -u

workspace="${TASK_WORKSPACE:-/workspace}"
secrets="${TASK_SECRETS_DIR:-/run/secrets}"
skills_src="${TASK_SKILLS_DIR:?set by task/Dockerfile}"

# Skills are image-managed: image files overwrite the home PVC's copy
# every boot. A file only the PVC has is left alone.
if [ -d "$skills_src" ]; then
  mkdir -p "$HOME/.claude/skills" \
    && cp -rf "$skills_src/." "$HOME/.claude/skills/" \
    || echo "WARN: could not seed skills into $HOME/.claude/skills" >&2
fi

# The clones below are the one git call the worker does not wrap, so they
# need the token in their own environment; a private repo cloned without
# it fails here and surfaces hours later as a stage with no checkout.
if [ -r "$secrets/git/token" ]; then
  GH_TOKEN="$(cat "$secrets/git/token")"
  export GH_TOKEN
else
  echo "WARN: no git token at $secrets/git/token; private repos will not clone" >&2
fi

# Per-pod repos by StatefulSet ordinal, from the Vault-backed claude-repos
# secret (pod<ordinal> files), falling back to CLONE_REPOS. The worker
# expects /workspace/<repo> to exist; it never clones. Space, comma or
# newline separated; full URLs or owner/repo slugs (assumed github.com).
# Idempotent: a repo dir that exists is left alone, whatever its state.
# A failed clone is a warning, not an exit: one bad entry in a list of
# two dozen must not keep the pod from serving every other repo's cards.
ORD="${HOSTNAME##*-}"
REPOS="$(cat "$secrets/repos/pod${ORD}" 2>/dev/null || echo "${CLONE_REPOS:-}")"
echo "pod ordinal=$ORD -> $(echo "$REPOS" | wc -w) repo(s)"
dirs=()
for r in $(echo "${REPOS:-}" | tr ',\n' '  '); do
  [ -z "$r" ] && continue
  case "$r" in
    http*://*|git@*) url="$r" ;;
    */*)             url="https://github.com/$r.git" ;;
    *)               echo "skip unrecognized repo ref: $r"; continue ;;
  esac
  dir="$workspace/$(basename "$r" .git)"
  dirs+=("$dir")
  if [ -d "$dir/.git" ]; then
    echo "repo present: $dir"
  else
    echo "cloning $url -> $dir"
    git clone "$url" "$dir" || echo "WARN: clone failed: $url"
  fi
done

# Pre-trust the workspace and every repo in it. The worker runs `claude -p`
# with the repo as its working directory; the interactive image found the
# CLI waiting on "Is this a project you trust?" for a directory it had not
# been told about, and nothing is attached here to answer.
node -e '
const fs = require("fs"), os = require("os"), path = require("path");
const f = path.join(os.homedir(), ".claude.json");
let d = {};
try { d = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) {}
d.hasCompletedOnboarding = true;
d.projects = d.projects || {};
for (const dir of process.argv.slice(1)) {
  const p = (d.projects[dir] = d.projects[dir] || {});
  p.hasTrustDialogAccepted = true;
  p.hasCompletedProjectOnboarding = true;
}
fs.writeFileSync(f, JSON.stringify(d, null, 2));
' "$workspace" "${dirs[@]}" || echo "WARN: could not write $HOME/.claude.json" >&2

exec sleep infinity
