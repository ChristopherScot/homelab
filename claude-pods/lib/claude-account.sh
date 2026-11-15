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
# rate_limit (underscore) as well as rate_limited: run.py:332 greps for
# the former in subtype, so the two must agree.
CLAUDE_LIMIT_REASONS='limit_reached|quota_exceeded|rate_limited|rate_limit|insufficient_credits|credit_balance_too_low|out_of_credits'

claude_terminal_reason_limited() {
  # A bare reason, as jq -r hands back.
  printf '%s' "$1" | grep -qE "^($CLAUDE_LIMIT_REASONS|api_error_429)$" && return 0
  # Or the same as a JSON value, for a caller passing whole output.
  # api_error_429 belongs in this list as well as the bare one: a 429
  # usually arrives as its own "api_error_status": 429 field, handled
  # below, but run.py composes stop_reason="api_error_429" from it
  # (run.py:413-416) and that form reached neither branch.
  printf '%s' "$1" | grep -qE \
    "\"(terminal_reason|subtype|stop_reason)\"[[:space:]]*:[[:space:]]*\"($CLAUDE_LIMIT_REASONS|api_error_429)\"" && return 0
  printf '%s' "$1" | grep -qE '"api_error_status"[[:space:]]*:[[:space:]]*429'
}

claude_rate_limited() {
  # Structured first, because it is the stronger signal - but the prose
  # branch below is now the HOT PATH, not a fallback waiting for a
  # caller. All three stages pass ~40 lines of transcript through it on
  # every run, and it is the only thing standing between a genuinely
  # exhausted account and a parked card. Read the rest of this comment
  # with that cost in mind: a miss here pings @chris, and a false match
  # spends the reserve account.
  #
  # The prose set stays deliberately narrow. A first draft of this fix
  # also matched `limit[ ·]+resets`, which looked like a safe
  # generalisation of the CLI's wording and instead matched "the limit
  # resets daily", "cache limit · resets on deploy" and "connection
  # limit resets after timeout" - any of which an agent could print
  # while discussing unrelated code, silently burning the personal
  # account on a run that was never limited. Only the CLI's own
  # "hit your <period> limit" is specific enough to add.
  #
  # Do not enumerate the period. This matched only [0-9]+-hour, and on
  # 2026-11-14 the CLI said "You've hit your weekly limit · resets Nov 16,
  # 11am (UTC)" - so detection missed it, the stage read a bare non-zero
  # exit, and the card was parked with a personal token mounted and
  # unused. Wiring the stages to this wrapper would NOT have saved that
  # card on its own.
  #
  # The first fix added weekly|daily|monthly, which was the same mistake
  # one step along. Strings pulled from the 2.1.325 binary show at least
  # seven shapes, and "weekly" is not even among them - it is assembled at
  # runtime:
  #
  #   hit your limit                          (no period at all)
  #   hit your session limit
  #   hit your fast limit
  #   hit your Fable limit                    (a model name)
  #   hit your monthly limit
  #   hit your monthly spend limit
  #   hit your channel's monthly spend limit
  #
  # So match the structure instead: "hit your <up to three short words>
  # limit". The word bound keeps it from running across a sentence into
  # an unrelated "limit", and the shape survives a model name (Opus,
  # Sonnet, Fable) or a period nobody has seen yet. Verified against the
  # 2.1.323 binary's own composer -
  #
  #   function H(e,n,r,s){let d=s?.progressSavedSuffix?" \xB7 progress saved":"";
  #                       return `You've hit your ${e}${n}${d}`}
  #
  # - over the 14 labels in its qbe/label maps (5-hour, session, weekly,
  # monthly, monthly spend, team's/channel's monthly spend, org's
  # monthly usage, usage credit, fast, Opus, Sonnet, Fable, and the bare
  # "limit") times the five suffixes: all 70 match.
  #
  # Those maps are NOT the whole label set, and an earlier version of
  # this comment claimed they were. H() also takes literal labels at its
  # call sites, and one of them does not end in the word "limit":
  #
  #   You've hit your team's shared budget. /model to switch models.
  #
  # The shape below required the sentence to end in "limit", so that
  # message - which the binary really does compose, in the group_pool
  # branch - was read as an ordinary failure: a card parked and @chris
  # pinged, the expensive direction. Hence `(limit|shared budget)`.
  #
  # The lesson is narrower than "enumerate harder". The CLI's own test is
  # a PREFIX match on "You've hit your" and ignores what follows, so any
  # shape derived from the tail of the sentence will keep losing labels
  # this way. A bare prefix match is what the CLI can afford because it
  # tests one message string; here it would also match an agent's own
  # line "You have hit your configured per-project eslint file count
  # limit", which tests/test-account-failover.sh pins as a negative. So
  # this stays shape-based and therefore INCOMPLETE BY CONSTRUCTION -
  # treat a newly-seen terminator as expected maintenance, not a
  # surprise, and add it here with a pinned shape in the test.
  #
  # EVERY alternate is anchored to the start of a line, and that is the
  # whole specificity mechanism now that the window is 40 lines rather
  # than 2. The CLI prints these as its own message, so they begin a
  # line; an agent discussing them does not. The distinction is not
  # hypothetical here - these stages edit THIS repository, so an agent
  # working on this very function is the likely false positive, and
  # unanchored alternates produced two:
  #
  #   {"status": 429, "body": "slow down"}        a 429 test fixture
  #   now covers "you have hit your weekly limit" a quoted mention
  #
  # The second is why the leading-junk allowance is {0,2} and not {0,4}:
  # it has to admit the CLI's own prefixes but not a quote plus
  # indentation. A limit message indented more than two characters is
  # not something the CLI emits.
  #
  # The first could not be fixed by anchoring at all, because `{"status":
  # 429, ...}` on its own line is precisely what a fixture looks like. It
  # was dropped instead, along with a bare `api_error_429`, after
  # checking the 2.1.323 binary: it contains ZERO occurrences of
  # `"status": 429` (the only quoted-key 429 in it is `"headline":"429`)
  # and no `api_error_429` anywhere - that token is composed by our own
  # run.py, not by the CLI. So neither alternate could ever match real
  # CLI output, while both matched an agent writing a 429 test fixture.
  # Every genuine 429 arrives structured and is caught above, by
  # `"api_error_status": 429` or by api_error_429 as a named key's value.
  # tests/test-account-failover.sh pins the fixture case.
  #
  # The prose set is ported from the CLI's own exhaustion predicate
  # rather than guessed at, since guessing is what failed twice here:
  #
  #   function yvs(e){return gvs.some((n)=>e.startsWith(n))
  #     ||_vs.some((n)=>n.test(e))}
  #   gvs=["You've hit your","You've reached your","You're out of usage
  #     credits","Your org is out of usage \xB7 add funds to continue",
  #     ... 12 entries ...]
  #   _vs=[/^(?:Fable|Haiku|Mythos|Opus|Sonnet)(?: [^\u00B7\n]{1,40})?
  #     requires usage credits\./]
  #
  # Two deliberate differences from that source. `fast mode` is added to
  # the model alternation: the binary emits "Fast mode requires usage
  # credits" but it is in neither gvs nor _vs, so a direct port missed
  # it - the pinned-shapes loop in the test caught that. And the
  # startsWith prefixes become ^-anchored line matches, because the CLI
  # tests one message string while we search a 40-line transcript.
  #
  # Keep this branch free of anything the CLI does not itself print. A
  # token that only ever appears in test data is not a weak signal here,
  # it is an inverted one: these stages edit this repository, so the
  # agent most likely to print it is the one working on this function.
  #
  # The structured tokens above are the better signal and are checked
  # first; this prose branch exists because the stages do not pass
  # --output-format json, so prose is all there is.
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
    "^[^[:alnum:]]*(error|warning)?:?[[:space:]]*rate.?limit(ed|[[:space:]]+(reached|exceeded))|(^|[[:space:]])(stop_)?reason=($CLAUDE_LIMIT_REASONS|api_error_429)([[:space:]]|\$)|^[^[:alnum:]]{0,2}you.?(ve|have) (hit|reached) your [^[:space:]]{0,24}([[:space:]][^[:space:]]{1,16}){0,2}[[:space:]]?(limit|shared budget)|^[^[:alnum:]]{0,2}you.?(re|are) out of (usage credits|extra usage)|^[^[:alnum:]]{0,2}your org is out of usage|^[^[:alnum:]]{0,2}your seat type does ?n.?t include (usage|extra usage)|^[^[:alnum:]]{0,2}your usage allocation has been disabled|^[^[:alnum:]]{0,2}your group.?s usage limit is set to \\\$0|^[^[:alnum:]]{0,2}(fable|haiku|mythos|opus|sonnet|fast mode)( [^\xB7]{1,40})? requires usage credits"
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

  # One attempt, under whichever account is selected. The redirect is
  # HERE, per call, and never once around this whole function - see the
  # --stdin note above for what the latter cost.
  #
  # No pipeline, deliberately. An earlier version of this wrote
  # `"$@" 2>&1 | tee /dev/stderr` to restore stage-author's live
  # streaming as well, and the pipeline cost the command's exit status:
  # `$?` became tee's, which is 0 whatever the command did, so rc was
  # never non-zero and the failover went silently dead. PIPESTATUS can
  # recover it, but needing that is the signal the helper was doing too
  # much - it was redirecting, teeing AND classifying. Streaming is a
  # separate change from the stdin contract and belongs in its own
  # commit; this one keeps the capture exactly as it was.
  _attempt() {
    if [ -n "$stdin_file" ]; then
      "$@" < "$stdin_file" 2>&1
    else
      "$@" 2>&1
    fi
  }

  if ! use_claude_account work; then
    echo "no work token; trying personal" >&2
    use_claude_account personal || {
      echo "FATAL: no Claude token for either account" >&2; return 1; }
    out="$(_attempt "$@")"; rc=$?
    printf '%s\n' "$out"
    return "$rc"
  fi

  out="$(_attempt "$@")"; rc=$?
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
      out="$(_attempt "$@")"; rc=$?
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

