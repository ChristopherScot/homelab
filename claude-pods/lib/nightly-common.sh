#!/usr/bin/env bash
# The preamble the three nightly scripts share: nightly-author (pod 0),
# nightly-test (pod 2) and nightly-merge (pod 1) each source this before
# doing anything of their own.
#
# One copy, because three copies held in step by hand did not stay in
# step: a helper added to one pod's script missed the others, and a fix
# to the credential preflight meant the same edit in three files (#59).
# Anything every pod needs lives here; anything one pod needs lives in
# its script.
#
# Sourced, never run. Sourcing it defines defaults and functions and does
# nothing else — no output, no exec, no exit — so a test can source it
# too. The image ships it at /usr/local/share/claude-pods/lib/ and the
# scripts find it through NIGHTLY_LIB.
#
# The scripts then call, in this order: log_to (before anything prints,
# or it is lost to Loki), require_gh_token, preflight_credential, and
# only then pick_model — its probe cannot tell a capped model from a dead
# credential, so the credential has to be known good first.
#
# The defaults below are set for the scripts that source this file; read
# on its own, some of them look unused to a linter.
# shellcheck disable=SC2034

# Namespace the session pods run in; preflight_credential looks for
# peers here.
NIGHTLY_NS="${NIGHTLY_NS:-claude-pods}"
# Only repos under this GitHub owner are worked on; each pod's repo list
# is filtered to it.
OWNER="${NIGHTLY_OWNER:-ChristopherScot}"
# Per-run state and logs, on the pod's PVC.
STATE_DIR="${NIGHTLY_STATE_DIR:-/workspace/.nightly}"

# --- Model -----------------------------------------------------------------
# Preferred model, with a fallback. Fable is first choice, but it sits
# behind a monthly spend cap that Opus does not — and a capped model fails
# every ticket with "You've hit your monthly spend limit" rather than
# degrading. Probed once per run so the job starts using Fable again by
# itself when the cap resets, instead of needing an edit.
MODEL="${NIGHTLY_MODEL:-claude-fable-5-1}"
MODEL_FALLBACK="${NIGHTLY_MODEL_FALLBACK:-opus}"
# Probes MODEL once; if the reply says it is capped or unavailable, sets
# MODEL to MODEL_FALLBACK (which is not probed). Reports the choice on
# stderr.
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
# render_prompt FILE: prints FILE with its $VAR references expanded from
# the environment; a $VAR that is not set is left as written. Exits the
# script if FILE is unreadable: with no prompt, every ticket would fail
# the same way.
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
  if [ -z "$GH_TOKEN" ]; then echo "FATAL: no GitHub token" >&2; return 1; fi
}

# Takes GH_TOKEN out of agent output before it is quoted anywhere public.
#
# The agent inherits GH_TOKEN so it can run gh, and the allow-list lets it
# run env and cat. Its output reaches pull requests on public repos, so
# the token is removed rather than trusted not to appear. Safe for a
# GitHub token because those are [A-Za-z0-9_]; a secret containing a
# backslash or the sed delimiter would need another way.
#
# Call require_gh_token first: with GH_TOKEN unset this passes its input
# through unchanged.
redact() {
  if [ -n "$GH_TOKEN" ]; then
    sed "s|$GH_TOKEN|[redacted]|g"
  else
    cat
  fi
}

# Wraps agent output for a public pull request. Unfenced, its markdown
# renders: a bare @name notifies that person, and #52 cross-links an
# issue back to this PR. Four backticks, because the agent's own output
# may contain a three-backtick fence.
fence() {
  printf '````\n%s\n````' "$(printf '%s' "$1" | tail -30 | redact)"
}

# Lands PR $2 (number or URL) in repo $1 (owner/name) and deletes its
# branch; exit status is gh's. Merge method is per-repo and squash is
# disabled across all of these, so asking for it unconditionally fails
# every merge ("Squash merges are not allowed on this repository"):
# squash if allowed, else a merge commit if allowed, else rebase (also
# the fallback when the repo's settings cannot be read). gh's stderr is
# deliberately not discarded: the reason for a refusal belongs in the log.
merge_pr() {
  local repo="$1" pr="$2" sha="${3:-}" method
  case "$(gh api "repos/$repo" --jq '"\(.allow_squash_merge) \(.allow_merge_commit)"' 2>/dev/null)" in
    "true "*) method=--squash ;;
    *" true") method=--merge ;;
    *)        method=--rebase ;;
  esac
  # With a SHA, the merge is refused if the branch moved since that
  # commit was judged. Without one — reverts, whose PR is seconds old and
  # has no verdict to be stale — there is nothing to pin to.
  if [ -n "$sha" ]; then
    gh pr merge "$pr" --repo "$repo" "$method" --match-head-commit "$sha" --delete-branch >/dev/null
  else
    gh pr merge "$pr" --repo "$repo" "$method" --delete-branch >/dev/null
  fi
}

# Undo merged PR $2 in repo $1 after it turned main red. `gh pr revert`
# only OPENS a revert pull request — it has no flag to land it — so
# landing it is a second, explicit step through merge_pr, the same way
# the original went in. Pushing a revert commit straight to main is not
# an alternative: the nightly-guard ruleset on these repos requires every
# change to main to arrive through a pull request.
#
# Prints nothing and exits non-zero if the revert PR could not be opened.
# Otherwise prints its URL as soon as it exists, then exits non-zero if
# it could not be merged — it is left open, and the URL lets the caller
# point the morning human at it.
revert_pr() {
  local repo="$1" pr="$2" url
  url=$(gh pr revert "$pr" --repo "$repo" \
          --body "Reverts #$pr. Opened by nightly-merge because main's CI went red after it landed.") \
    || return 1
  echo "$url"
  # GitHub works out a new PR's mergeability in the background, and a
  # merge asked for before that finishes is refused as "not mergeable"
  # although nothing is wrong. This PR is seconds old, so allow a few
  # tries before calling it failed. (The sleep is an env knob only so the
  # test's permanent-failure case does not wait a minute.)
  local _
  for _ in 1 2 3 4 5 6; do
    merge_pr "$repo" "$url" && return 0
    sleep "${NIGHTLY_REVERT_RETRY_SLEEP:-10}"
  done
  return 1
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
#
# cred_ok POD: 0 if POD's ~/.claude/.credentials.json holds non-empty
# access and refresh tokens and an expiry still in the future; 1
# otherwise, including when kubectl cannot reach POD.
cred_ok() {
  kubectl exec -n "$NIGHTLY_NS" "$1" -- node -e '
    const f = process.env.HOME + "/.claude/.credentials.json";
    let d; try { d = require(f).claudeAiOauth; } catch (e) { process.exit(1); }
    if (!d || !d.accessToken || !d.refreshToken) process.exit(1);
    if (!(d.expiresAt > Date.now())) process.exit(1);
  ' >/dev/null 2>&1
}

# Returns 0 once this pod has a usable credential — repairing it from a
# healthy peer if it must, which overwrites ~/.claude/.credentials.json —
# or 1 if none could be found, or found but not copied.
preflight_credential() {
  local me="${HOSTNAME:-unknown}"
  if cred_ok "$me"; then
    echo "credential: ok"
    return 0
  fi
  echo "credential: INVALID on $me — looking for a healthy peer" >&2
  local peer
  for peer in $(kubectl get pods -n "$NIGHTLY_NS" -l app=claude-session \
                  --field-selector status.phase=Running \
                  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    [ "$peer" = "$me" ] && continue
    if cred_ok "$peer"; then
      kubectl exec -n "$NIGHTLY_NS" "$peer" -- cat /home/node/.claude/.credentials.json 2>/dev/null \
        | kubectl exec -i -n "$NIGHTLY_NS" "$me" -- sh -c 'umask 077; cat > "$HOME/.claude/.credentials.json"' 2>/dev/null
      if cred_ok "$me"; then
        echo "credential: repaired from $peer" >&2
        return 0
      fi
    fi
  done
  echo "FATAL: no pod has a usable credential; run scripts/claude-pods-login.sh" >&2
  return 1
}
