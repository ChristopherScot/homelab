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
# The exhaustion reasons the CLI and SDK report, matched in two shapes.
#
# The BARE form is the one in use: nightly-desloppify.sh passes
# `jq -r .stop_reason`, a single word. A first draft matched only the
# JSON form, so the runner's limit_reached never matched and the retry
# it was meant to trigger still did not fire.
#
# The JSON form still has no caller, but for a narrower reason than it
# used to: all three stages now DO go through run_with_account_failover,
# they just do not pass --output-format json, so what reaches the
# detector is prose. This branch is what will read their output when
# that lands. (This comment previously said the stages invoked `claude
# -p` bare and were not covered. That was true when written and is the
# exact thing PR 187 changed - tests/test-account-failover.sh now fails
# the build if any stage stops calling the wrapper.)
#
# rate_limit (underscore) as well as rate_limited: run.py greps for
# `rate_limit` in `message.subtype`, so the two must agree. (Cited by
# symbol, not line: the line number was already wrong by 13 lines.)
CLAUDE_LIMIT_REASONS='limit_reached|quota_exceeded|rate_limited|rate_limit|insufficient_credits|credit_balance_too_low|out_of_credits'

claude_terminal_reason_limited() {
  # A bare reason, as jq -r hands back.
  printf '%s' "$1" | grep -qE "^($CLAUDE_LIMIT_REASONS|api_error_429)$" && return 0
  # Or the same as a JSON value, for a caller passing whole output.
  # api_error_429 belongs in this list as well as the bare one: a 429
  # usually arrives as its own "api_error_status": 429 field, handled
  # below, but run.py composes stop_reason="api_error_429" from its
  # api_error_status (see the report dict in run.py) and that form
  # reached neither branch.
  printf '%s' "$1" | grep -qE \
    "\"(terminal_reason|subtype|stop_reason)\"[[:space:]]*:[[:space:]]*\"($CLAUDE_LIMIT_REASONS|api_error_429)\"" && return 0
  printf '%s' "$1" | grep -qE '"api_error_status"[[:space:]]*:[[:space:]]*429'
}

claude_rate_limited() {
  # True when CMD's output says the account is out of quota. Takes the
  # text to examine - a bare reason word, a JSON blob, or a window of
  # transcript - and checks the structured signals first because they
  # are unambiguous, then the CLI's prose.
  #
  # This is the HOT PATH, not a fallback: all three stages pass ~40
  # lines of transcript through it on every run, and it is the only
  # thing between a genuinely exhausted account and a parked card. A
  # miss pings @chris; a false match spends the reserve account on a
  # run that was never limited.
  #
  # The prose alternates are a PORT of the CLI's own exhaustion
  # predicate, not a guess at its wording - two earlier versions
  # guessed and both were wrong in production.
  #
  # yvs() is only HALF that predicate, which is the third time a reading
  # of this binary has come up short. Its real call site is
  # `dailyCapPaused === true || yvs(rt)`, and the left disjunct is a
  # separate rate_limit branch with a message sharing no vocabulary with
  # the right one:
  #
  #   case "api_error": if (e.errorKind === "rate_limit") {
  #     if (e.quotaLimits?.dailyCapPaused === true)
  #       return {kind:"pause", cause:"daily_cap"};
  #
  #   "Usage is paused for your organization. For help, please contact
  #    support."                                     (bNe in the binary)
  #   "This service is disabled for your org"        (vVi, a sibling)
  #
  # Both are matched below. An org daily-cap pause would otherwise park
  # the card with the reserve token mounted and unused - the 2026-11-14
  # failure with a different trigger. Every alternate is
  # anchored to the start of a line, which is what separates the CLI
  # printing its own message from an agent quoting one; that matters
  # because these stages edit THIS repository.
  #
  # The shape is incomplete by construction: it matches on how the
  # sentence ENDS while the CLI matches how it BEGINS, so a new label
  # ending differently will be missed - `team's shared budget` already
  # was. Adding a newly-seen terminator here, plus a pinned shape in
  # tests/test-account-failover.sh, is expected maintenance.
  #
  # Claims here were verified against the binary on the maintainer's
  # machine, 2.1.323 (~/.local/share/claude/versions/2.1.323), which is
  # NOT the version the image pins (CLAUDE_CODE_VERSION in the
  # Dockerfile). Re-verify against the pin when it is available.
  #
  # Full reasoning - the three attempts, what was ported and why, the
  # deliberately excluded alternates, and the detection window - is in
  # claude-pods/designNotes.md under "Limit detection". It lives there
  # because it spans the CLI binary, run.py, nightly-desloppify.sh and
  # three stage scripts, so no one function is its home.
  #
  # $CLAUDE_LIMIT_REASONS is INTERPOLATED, never retyped: it was
  # retyped once and the copy had already lost two values, so the bare
  # and key=value forms silently disagreed.
  claude_terminal_reason_limited "$1" && return 0
  #
  # $CLAUDE_LIMIT_REASONS is INTERPOLATED, not retyped. It was retyped
  # once, and the copy had already lost `rate_limit` and
  # `credit_balance_too_low` - so `stop_reason=rate_limit` in a stage
  # transcript read as an ordinary failure while a bare `rate_limit`
  # from desloppify read as a limit. The variable exists to be the one
  # home of that list (nightly-desloppify.sh:380 says so); reaching
  # around it is how the two forms diverge silently.
  printf '%s' "$1" | grep -qiE \
    "^[^[:alnum:]]*(error|warning)?:?[[:space:]]*rate.?limit(ed|[[:space:]]+(reached|exceeded))|(^|[[:space:]])(stop_)?reason=($CLAUDE_LIMIT_REASONS|api_error_429)([[:space:]]|\$)|^[^[:alnum:]]{0,2}you.?(ve|have) (hit|reached) your [^[:space:]]{0,24}([[:space:]][^[:space:]]{1,16}){0,2}[[:space:]]?(limit|shared budget)|^[^[:alnum:]]{0,2}you.?(re|are) out of (usage credits|extra usage)|^[^[:alnum:]]{0,2}your org is out of usage|^[^[:alnum:]]{0,2}your seat type does ?n.?t include (usage|extra usage)|^[^[:alnum:]]{0,2}your usage allocation has been disabled|^[^[:alnum:]]{0,2}your group.?s usage limit is set to \\\$0|^[^[:alnum:]]{0,2}usage is paused for your organi[sz]ation|^[^[:alnum:]]{0,2}this service is disabled for your org|^[^[:alnum:]]{0,2}(fable|haiku|mythos|opus|sonnet|fast mode)( [^\xB7]{1,40})? requires usage credits"
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

