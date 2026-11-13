#!/usr/bin/env bash
# Claude account selection, shared by every pod that runs the CLI.
#
# Separate from pod-common.sh because that file carries kubectl,
# Kaneo and namespace machinery the desloppify pod has no use for, and
# sourcing all of it to get two functions would couple the two images
# together for no reason.
#
# No side effects on source: nothing here runs until called.

# --- Claude credential -----------------------------------------------------
# A `claude setup-token` credential, from Vault, in the environment.
#
# This replaces the ~/.claude/.credentials.json path the session pods used
# to depend on. That file was periodically found with accessToken and
# refreshToken as EMPTY STRINGS and expiresAt=0 - valid JSON, right shape,
# no tokens - which read as expired-in-1970 and could not renew, because
# the refresh token it would renew with was blanked too. The repair for
# that was to copy a healthy peer's file over the broken one.
#
# A setup-token credential is valid for a year and never refreshes, so
# there is nothing to blank and no peer to copy from. CLAUDE_CODE_OAUTH_TOKEN
# also takes precedence over the file when set, so nothing else has to
# change for the CLI to use it.
#
# Two accounts, because a rate limit is per account and exhausting one
# should not end the night. Work is tried first; personal is the reserve.
CLAUDE_TOKEN_DIR="${CLAUDE_TOKEN_DIR:-/run/secrets/claude}"

# use_claude_account work|personal
# Exports CLAUDE_CODE_OAUTH_TOKEN, or returns 1 if that account has no
# token mounted. Also clears the API-key variables: either of them
# silently outranks the OAuth token and bills per token against the API
# account instead of the subscription.
use_claude_account() {
  local which="$1" file
  case "$which" in
    work)     file="$CLAUDE_TOKEN_DIR/oauth-token" ;;
    personal) file="$CLAUDE_TOKEN_DIR/oauth-token-personal" ;;
    *) echo "use_claude_account: unknown account '$which'" >&2; return 2 ;;
  esac
  local token
  token="$(cat "$file" 2>/dev/null)"
  [ -n "$token" ] || return 1
  CLAUDE_CODE_OAUTH_TOKEN="$token"
  export CLAUDE_CODE_OAUTH_TOKEN
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
  CLAUDE_ACCOUNT="$which"
  export CLAUDE_ACCOUNT
  return 0
}

# claude_rate_limited TEXT
# 0 if TEXT looks like an account that has run out rather than a failure
# of the work itself. A rate-limited run fails in seconds with no tool
# calls, so this is cheap to detect and cheap to retry.
# Two checks, because prose is the weaker signal and we were caught by
# it once. On 2026-11-09 an author run was cut off mid-review-cycle by
# "You've hit your 5-hour limit · resets 10:10pm (UTC)" - no "rate
# limit", no "usage limit", no 429 - so the failover never fired, the
# personal account sat unused, and the card parked in Backlog as
# "produced no pull request" with nothing saying the account had run
# out.
#
# Prefer the machine-readable reason. `claude --output-format json`
# returns terminal_reason and api_error_status, the same fields the SDK
# path in desloppify-pod/run.py already reads, and the CLI binary
# carries the token values "limit_reached" and "quota_exceeded". Those
# are identifiers; the sentence above is marketing copy that can be
# reworded without notice.
# The exhaustion reasons the CLI and SDK report. Matched two ways,
# because callers hand this either whole JSON or a single extracted
# value: nightly-desloppify.sh passes `jq -r .stop_reason`, which is a
# BARE word, while a stage passing raw output has the "key": "value"
# shape. A first draft matched only the latter, so the runner's
# limit_reached never matched and the retry it was meant to trigger
# still did not fire.
#
# rate_limit (underscore) as well as rate_limited: run.py:332 greps for
# the former in subtype, so the two must agree.
CLAUDE_LIMIT_REASONS='limit_reached|quota_exceeded|rate_limited|rate_limit|insufficient_credits|credit_balance_too_low'

claude_terminal_reason_limited() {
  # A bare reason, as jq -r hands back.
  printf '%s' "$1" | grep -qE "^($CLAUDE_LIMIT_REASONS|api_error_429)$" && return 0
  # Or the same as a JSON value, for a caller passing whole output.
  printf '%s' "$1" | grep -qE \
    "\"(terminal_reason|subtype|stop_reason)\"[[:space:]]*:[[:space:]]*\"($CLAUDE_LIMIT_REASONS)\"" && return 0
  printf '%s' "$1" | grep -qE '"api_error_status"[[:space:]]*:[[:space:]]*429'
}

claude_rate_limited() {
  # Structured first; prose only as the fallback for text output, which
  # is what the stage scripts still produce.
  #
  # The prose set stays deliberately narrow. A first draft of this fix
  # also matched `limit[ ·]+resets`, which looked like a safe
  # generalisation of the CLI's wording and instead matched "the limit
  # resets daily", "cache limit · resets on deploy" and "connection
  # limit resets after timeout" - any of which an agent could print
  # while discussing unrelated code, silently burning the personal
  # account on a run that was never limited. Only the CLI's own
  # "hit your N-hour limit" is specific enough to add.
  claude_terminal_reason_limited "$1" && return 0
  printf '%s' "$1" | grep -qiE \
    'api_error_429|"?status"?[: ]+429|rate.?limit|usage limit|quota exceeded|you.?(ve|have) hit your [0-9]+-hour limit'
}

# run_with_account_failover CMD...
# Runs CMD under the work account; if it fails and the output says the
# account is exhausted, runs it once more under personal. Returns the
# exit status of whichever attempt ran last, and echoes CMD's output
# either way so a caller can still parse a report out of it.
run_with_account_failover() {
  local out rc
  if ! use_claude_account work; then
    echo "no work token; trying personal" >&2
    use_claude_account personal || {
      echo "FATAL: no Claude token for either account" >&2; return 1; }
    out="$("$@" 2>&1)"; rc=$?
    printf '%s\n' "$out"
    return "$rc"
  fi

  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && claude_rate_limited "$out"; then
    if use_claude_account personal; then
      echo "work account is rate limited; retrying on personal" >&2
      out="$("$@" 2>&1)"; rc=$?
    else
      echo "work account is rate limited and no personal token is mounted" >&2
    fi
  fi
  printf '%s\n' "$out"
  return "$rc"
}

# Returns 0 once this pod has a usable token for at least one account.
preflight_credential() {
  if use_claude_account work; then
    echo "credential: work account"
    return 0
  fi
  if use_claude_account personal; then
    echo "credential: work token missing, using personal" >&2
    return 0
  fi
  # No mounted token is not yet an error. The session pods still
  # authenticate through ~/.claude/.credentials.json and have no
  # /run/secrets/claude mount; migrating them needs their own
  # setup-token credential in Vault and is a separate change. Until
  # then, saying "no token here" and letting the CLI use the file it
  # has always used is correct - refusing would stop all three stages
  # that work today.
  if [ -s "$HOME/.claude/.credentials.json" ]; then
    echo "credential: no mounted token; using the CLI's own login" >&2
    return 0
  fi
  echo "FATAL: no Claude token mounted at $CLAUDE_TOKEN_DIR, and no" >&2
  echo "       ~/.claude/.credentials.json to fall back to." >&2
  echo "       mint one with \`claude setup-token\` and write it to Vault" >&2
  return 1
}

