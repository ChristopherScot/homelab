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

# Exhaustion reasons, as the CLI reports them in `terminal_reason` /
# `subtype` / `stop_reason`. Also matched bare, because
# nightly-desloppify.sh passes `jq -r .stop_reason` directly.
CLAUDE_LIMIT_REASONS='limit_reached|quota_exceeded|rate_limited|rate_limit|usage_limit_reached|insufficient_credits|credit_balance_too_low|out_of_credits'

# claude_result_text JSON
# The agent's prose, which --output-format json puts in .result.
# Returns the input unchanged if it is not JSON, so a run that died
# before emitting its result object still logs something.
claude_result_text() {
  printf '%s\n' "$1" | tail -1 | jq -re '.result' 2>/dev/null || printf '%s' "$1"
}

# claude_rate_limited TEXT
# True when TEXT says the account is out of quota.
#
# TEXT is either a bare reason word or the JSON from a run with
# `--output-format json`. On an error the CLI prints a diagnostic line
# before the JSON object, so the object is read from the last line.
claude_rate_limited() {
  local reason
  for reason in $(printf '%s' "$CLAUDE_LIMIT_REASONS" | tr '|' ' ') api_error_429; do
    [ "$1" = "$reason" ] && return 0
  done

  printf '%s\n' "$1" | tail -1 | jq -e --arg r "$CLAUDE_LIMIT_REASONS" '
      ($r | split("|") + ["api_error_429"]) as $limited
      | .api_error_status? == 429
        or ([.terminal_reason?, .subtype?, .stop_reason?] - [null]
            | any(. as $v | $limited | index($v)))
    ' >/dev/null 2>&1
}


# _claude_attempt STDIN_FILE_OR_EMPTY CMD...
# Runs CMD once, with stdin from STDIN_FILE when non-empty, merging
# stderr into stdout. Returns CMD's exit status.
#
# Defined at file scope, not nested inside run_with_account_failover.
# Bash has no local functions: a nested definition is installed in the
# CALLER's global namespace the first time the enclosing function runs
# and outlives the call, so `_attempt` read as private while being
# visible to every stage script that sources this file. Verified:
# `type -t _attempt` is undefined before the first call and `function`
# after it. Nothing collided, but the privacy was apparent rather than
# real, and a nested version also closed over $stdin_file - so neither
# half could be read without the other.
#
# No pipeline in here. Adding `| tee` to restore live streaming cost
# the command's exit status ($? becomes tee's, which is 0 whatever the
# command did) and silently disabled the failover. Streaming is a
# separate change; this helper does one thing.
_claude_attempt() {
  local stdin_file=$1; shift
  if [ -n "$stdin_file" ]; then
    "$@" < "$stdin_file" 2>&1
  else
    "$@" 2>&1
  fi
}

# run_with_account_failover [--stdin FILE] CMD...
# Runs CMD under the work account; if it fails and the output says the
# account is exhausted, runs it once more under personal. Returns the
# exit status of whichever attempt ran last, and echoes CMD's output
# either way so a caller can still parse a report out of it.
#
# Pass the prompt with --stdin FILE, never by redirecting this function.
# A redirect on the caller's side attaches to the whole function, so the
# first attempt reads the prompt to EOF and the retry inherits a drained
# descriptor: the reserve account then runs the agent with an EMPTY
# PROMPT. That is not hypothetical - all three stages did exactly this
# (`out=$(run_with_account_failover ... < prompt.txt)`) and a repro with
# a fake claude that reads stdin showed attempt 1 getting 73 bytes and
# attempt 2 getting 0. It would have spent the reserve account on the
# 2026-11-14 card and parked it anyway, defeating the point of failing
# over at all. The suite missed it for the same reason it missed the
# unwired stages: none of its fake commands read stdin.
#
# --stdin makes the prompt a parameter, so each attempt opens the file
# for itself and both get the same bytes.
run_with_account_failover() {
  local out rc stdin_file=""
  if [ "${1:-}" = "--stdin" ]; then
    stdin_file=$2; shift 2
    [ -r "$stdin_file" ] || {
      echo "FATAL: --stdin $stdin_file is not readable" >&2; return 1; }
  fi

  if ! use_claude_account work; then
    echo "no work token; trying personal" >&2
    use_claude_account personal || {
      echo "FATAL: no Claude token for either account" >&2; return 1; }
    out="$(_claude_attempt "$stdin_file" "$@")"; rc=$?
    printf '%s\n' "$out"
    return "$rc"
  fi

  out="$(_claude_attempt "$stdin_file" "$@")"; rc=$?
  # Detect on a WINDOW of the tail, not the whole transcript and not a
  # needle at the very end. Both extremes were tried here and both were
  # wrong, in opposite directions:
  #
  # Whole transcript: the capture is an hour of agent prose plus the
  # CLI's stderr, so a ticket that merely edited a file named
  # rate_limit.go and then failed its tests read as a limited account
  # and burned a full second run on the reserve one. (That specific
  # example no longer matches, because the alternates are now anchored -
  # see claude_rate_limited. The reasoning is kept because the shape of
  # the mistake is what matters: the longer the haystack, the more of
  # the agent's own words are in it.)
  #
  # tail -2: a real limit is NOT the last thing printed. The CLI appends
  # "· progress saved" to the limit line, and a -p run prints its own
  # epilogue after ("Total cost: $X", "Total duration: Nm"). Driven
  # through this wrapper with a fake command, a real limit three lines
  # from the end was missed entirely and the reserve was never tried -
  # the exact 2026-11-14 failure, reintroduced by the fix for it.
  #
  # So specificity lives in the PATTERN, which is anchored to line
  # starts on the CLI's own sentences, and the window only has to be
  # wide enough that the message cannot fall outside it. 40 lines covers
  # any epilogue. Widening it further is not the hazard it would have
  # been before the anchoring, which is why the test pins that a bound
  # exists rather than pinning the number 40.
  # rc=124 is `timeout` killing a wedged run, which is not an exhausted
  # account. Both the stages and this file already treat it as its own
  # thing (stage-merge and stage-author branch on 124 explicitly) and
  # only this condition forgot. Without the exclusion, a run that
  # printed a limit line within the last 40 lines before wedging - these
  # stages edit this very file, so that is reachable - earns a second
  # full PER_TICKET_TIMEOUT on the reserve for nothing. 124 still
  # propagates out of this function unchanged, so the stages' own
  # handling of it is unaffected.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] \
     && claude_rate_limited "$(printf '%s' "$out" | tail -40)"; then
    if use_claude_account personal; then
      echo "work account is rate limited; retrying on personal" >&2
      out="$(_claude_attempt "$stdin_file" "$@")"; rc=$?
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
  # No mounted token is not yet an error. The session pods and the
  # desloppify pod both mount one now, but a pod built from an older
  # manifest, or a local run of these scripts, has only the CLI's own
  # login file. Saying "no token here" and letting the CLI use it is
  # correct - refusing would stop a pod that works today.
  if [ -s "$HOME/.claude/.credentials.json" ]; then
    echo "credential: no mounted token; using the CLI's own login" >&2
    return 0
  fi
  echo "FATAL: no Claude token mounted at $CLAUDE_TOKEN_DIR, and no" >&2
  echo "       ~/.claude/.credentials.json to fall back to." >&2
  echo "       mint one with \`claude setup-token\` and write it to Vault" >&2
  return 1
}

