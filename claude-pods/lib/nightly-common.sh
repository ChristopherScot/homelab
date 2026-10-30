#!/usr/bin/env bash
# The preamble the three nightly scripts share: nightly-author (pod 0),
# nightly-test (pod 2) and nightly-merge (pod 1) each source this before
# doing anything of their own.
#
# One copy, because three copies held in step by hand did not stay in
# step. The redaction rule reached pod 2 and not pod 1, and a fix to the
# credential preflight meant the same edit in three files (#59). Anything
# every pod needs lives here; anything one pod needs lives in its script.
#
# Sourced, never run. Sourcing it defines defaults and functions and does
# nothing else — no output, no exec, no exit — so a test can source it
# too. The image ships it at /usr/local/share/claude-pods/lib/ and the
# scripts find it through NIGHTLY_LIB.
#
# The defaults below are set for the scripts that source this file; read
# on its own, some of them look unused to a linter.
# shellcheck disable=SC2034

# --- Model -----------------------------------------------------------------
# Preferred model, with a fallback. Fable is first choice, but it sits
# behind a monthly spend cap that Opus does not — and a capped model fails
# every ticket with "You've hit your monthly spend limit" rather than
# degrading. Probed once per run so the job starts using Fable again by
# itself when the cap resets, instead of needing an edit.
MODEL="${NIGHTLY_MODEL:-claude-fable-5-1}"
MODEL_FALLBACK="${NIGHTLY_MODEL_FALLBACK:-opus}"
pick_model() {
  local probe
  probe=$(cd /workspace && timeout 120 claude -p --model "$MODEL" "Reply with exactly: OK" 2>&1 | tail -2)
  if printf '%s' "$probe" | grep -qiE "spend limit|rate limit|not support this model|unavailable"; then
    echo "model $MODEL unavailable ($(printf '%s' "$probe" | head -1)); falling back to $MODEL_FALLBACK" >&2
    MODEL="$MODEL_FALLBACK"
  fi
  echo "using model: $MODEL" >&2
}

# --- Prompts ---------------------------------------------------------------
# Prompts live as plain files so they can be edited and reviewed on their
# own. Expand $VAR references in them without running the text through a
# shell — the prompts contain backticks and quotes, and `eval` on them
# would be both fragile and an injection path from issue titles.
PROMPT_DIR="${NIGHTLY_PROMPT_DIR:-/usr/local/share/claude-pods/prompts}"
# acceptEdits allows file edits but NOT shell commands, so without an
# explicit allow-list every gh / go test / kubectl call stops for an
# approval nobody is there to give. Scoped list, not bypassPermissions.
NIGHTLY_SETTINGS="${NIGHTLY_SETTINGS:-/usr/local/share/claude-pods/prompts/nightly-settings.json}"
render_prompt() {
  local f="$1"
  if [ ! -r "$f" ]; then
    echo "FATAL: prompt not readable: $f" >&2
    exit 1
  fi
  # node, not python3: python3 is not installed in this image. It appeared
  # to work when probed through an interactive shell, but `kubectl exec`
  # gets a plain PATH and every ticket died on "python3: command not
  # found" before a prompt was ever rendered.
  node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
process.stdout.write(src.replace(/\$(\w+)/g, (m, k) =>
  Object.prototype.hasOwnProperty.call(process.env, k) ? process.env[k] : m));
' "$f"
}

# --- Where the run's output goes -------------------------------------------
OWNER="${NIGHTLY_OWNER:-ChristopherScot}"
STATE_DIR="${NIGHTLY_STATE_DIR:-/workspace/.nightly}"

# log_to FILE: from here on, everything the script prints goes to FILE on
# the PVC AND to pid 1's stdout, so the run shows up in Loki.
#
# These scripts run under `kubectl exec`, which is a separate process from
# the container's pid 1 (`sleep infinity`, which stops writing after the
# entrypoint finishes). Their output goes to the exec stream and never
# reaches container stdout, so Alloy had nothing to collect and a whole
# 2am run left no trace in Grafana — queryable only as a file inside a
# PVC. Writing to /proc/1/fd/1 puts it where the log collector looks.
#
# Falls back to the file alone if that fd is not writable, rather than
# losing the log entirely.
log_to() {
  local log="$1"
  mkdir -p "$(dirname "$log")"
  if [ -w /proc/1/fd/1 ]; then
    exec > >(tee -a "$log" > /proc/1/fd/1) 2>&1
  else
    exec > >(tee -a "$log") 2>&1
  fi
}

# --- GitHub ----------------------------------------------------------------
# Exports GH_TOKEN from the Vault-mounted secret; fails if there is none,
# since every gh call after this would.
require_gh_token() {
  GH_TOKEN="$(cat /run/secrets/git/token 2>/dev/null)"
  export GH_TOKEN
  if [ -z "$GH_TOKEN" ]; then echo "FATAL: no GitHub token"; return 1; fi
}

# --- Claude credential -----------------------------------------------------
# Refuse to start on a credential that cannot work.
#
# ~/.claude/.credentials.json is periodically found with accessToken and
# refreshToken as EMPTY STRINGS and expiresAt=0. Valid JSON, right shape,
# no tokens. Claude Code reads it as expired-in-1970 and cannot renew,
# because the refresh token it would renew with was blanked too.
#
# Cause unknown. It has hit different pods on different nights, and never
# all three at once — so a healthy peer is normally available to copy
# from. Without this check the run burns its whole window failing every
# ticket on "OAuth session expired".
cred_ok() {
  kubectl exec -n "${NIGHTLY_NS:-claude-pods}" "$1" -- node -e '
    const f = process.env.HOME + "/.claude/.credentials.json";
    let d; try { d = require(f).claudeAiOauth; } catch (e) { process.exit(1); }
    if (!d || !d.accessToken || !d.refreshToken) process.exit(1);
    if (!(d.expiresAt > Date.now())) process.exit(1);
  ' >/dev/null 2>&1
}

preflight_credential() {
  local me="${HOSTNAME:-unknown}"
  if cred_ok "$me"; then
    echo "credential: ok"
    return 0
  fi
  echo "credential: INVALID on $me — looking for a healthy peer" >&2
  local peer
  for peer in $(kubectl get pods -n "${NIGHTLY_NS:-claude-pods}" -l app=claude-session \
                  --field-selector status.phase=Running \
                  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    [ "$peer" = "$me" ] && continue
    if cred_ok "$peer"; then
      kubectl exec -n "${NIGHTLY_NS:-claude-pods}" "$peer" -- cat /home/node/.claude/.credentials.json 2>/dev/null \
        | kubectl exec -i -n "${NIGHTLY_NS:-claude-pods}" "$me" -- sh -c 'umask 077; cat > "$HOME/.claude/.credentials.json"' 2>/dev/null
      if cred_ok "$me"; then
        echo "credential: repaired from $peer" >&2
        return 0
      fi
    fi
  done
  echo "FATAL: no pod has a usable credential; run scripts/claude-pods-login.sh" >&2
  return 1
}
