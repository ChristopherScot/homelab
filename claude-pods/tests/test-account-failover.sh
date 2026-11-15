#!/usr/bin/env bash
# Work account first, personal only when work is out of quota.
#
# A quota is per account, so exhausting one should not end the night -
# but failing over on the wrong signal spends the reserve on an ordinary
# error, and failing over on none wastes it entirely. Both directions
# are checked.
#
# Detection reads the CLI's JSON (terminal_reason / subtype /
# stop_reason / api_error_status), never the agent's prose. There are
# therefore no CLI message strings pinned in this file: an earlier
# version scraped those sentences and needed 23 of them, each one a
# shape someone had to discover.
set -uo pipefail
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
here_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export CLAUDE_TOKEN_DIR="$tmp/secrets"
mkdir -p "$CLAUDE_TOKEN_DIR"
printf 'work-token' > "$CLAUDE_TOKEN_DIR/oauth-token"
printf 'personal-token' > "$CLAUDE_TOKEN_DIR/oauth-token-personal"

# shellcheck disable=SC1091
NIGHTLY_NS=test . "$here_dir/../lib/pod-common.sh" 2>/dev/null

# A result object, the way the CLI emits one. Used everywhere below so
# the shape is written once: a dozen hand-typed
# {"terminal_reason":"limit_reached"} literals is how the shape and the
# reason drift apart.
#   result_json REASON [extra-jq-fields-json]
result_json() {
  jq -cn --arg r "$1" --argjson extra "${2:-{\}}" '{terminal_reason:$r} + $extra'
}

# Reasons that are NOT out of quota. The complement of
# $CLAUDE_LIMIT_REASONS, and the other list this suite needs; stated
# here because the library has no reason to enumerate them.
NON_LIMIT_REASONS="completed timeout max_turns budget no_result error"

# --- what counts as out of quota -------------------------------------
# Anchored on a REAL exhausted-account result, captured from
# desloppify-0 on 2026-11-15 and kept verbatim in
# fixtures/limit-reached.json. Asserting against a captured object
# rather than a hand-typed one is the whole point: the previous version
# of this suite passed with eight invented reason words, none of which a
# real limit sets.
limit_fixture="$here_dir/fixtures/limit-reached.json"
[ -f "$limit_fixture" ] || { echo "FAIL: missing $limit_fixture"; exit 1; }

claude_rate_limited "$(cat "$limit_fixture")" \
  || { echo "FAIL: the captured real limit was not detected"; fail=1; }

# Same object pretty-printed and behind the diagnostic line the CLI
# prints before the JSON on some errors. Both shapes reach the detector.
claude_rate_limited "$(jq . "$limit_fixture")" \
  || { echo "FAIL: a multi-line result object was missed"; fail=1; }
claude_rate_limited "[claude-code:unrecognized_model] {\"model\":\"x\"}
$(jq -c . "$limit_fixture")" \
  || { echo "FAIL: a limit behind a diagnostic line was missed"; fail=1; }

# The 429 status alone is enough.
claude_rate_limited "$(result_json api_error '{"api_error_status":429}')" \
  || { echo "FAIL: api_error_status 429 alone was missed"; fail=1; }

# Each apiError on the CLI's error:"rate_limit" path, alone, with no
# status beside it. Each is per-account, which is the only reason
# failing over helps; the captured fixture is a plan limit (weekly)
# while the other two are credit exhaustion, which no capture covers.
#
# Written out HERE rather than iterating $CLAUDE_LIMIT_API_ERRORS. A
# loop over the library's own list cannot catch a value being deleted
# from it, because deleting the value also deletes its test - verified:
# dropping any of the three left this suite green. So this list is the
# specification and the cross-check below holds the two together.
EXPECT_API_ERRORS="usage_limit_reached model_requires_usage_credits long_context_credits_required"
for e in $EXPECT_API_ERRORS; do
  claude_rate_limited "$(result_json api_error "$(jq -cn --arg e "$e" '{api_error:$e}')")" \
    || { echo "FAIL: api_error '$e' alone was missed"; fail=1; }
done
for e in $EXPECT_API_ERRORS; do
  case " $CLAUDE_LIMIT_API_ERRORS " in
    *" $e "*) ;;
    *) echo "FAIL: '$e' was removed from CLAUDE_LIMIT_API_ERRORS"; fail=1 ;;
  esac
done
for e in $CLAUDE_LIMIT_API_ERRORS; do
  case " $EXPECT_API_ERRORS " in
    *" $e "*) ;;
    *) echo "FAIL: CLAUDE_LIMIT_API_ERRORS has '$e', which this suite does not pin"
       echo "      add it to EXPECT_API_ERRORS, and say why failover helps for it"
       fail=1 ;;
  esac
done

# Everything else in that enum must NOT fail over: same terminal_reason
# ("api_error"), same shape, but a second account cannot help.
for e in empty_completion max_output_tokens hook_denied no_response \
         unattended_start_limit no_allowed_fallback media_removed \
         stream_idle_timeout provider_credentials
do
  claude_rate_limited "$(result_json api_error "$(jq -cn --arg e "$e" '{api_error:$e}')")" \
    && { echo "FAIL: api_error '$e' is not a quota problem but read as one"; fail=1; }
done

# desloppify gets a bare word instead of the object: run.py composes it
# as f"api_error_{result.api_error_status}". DERIVED from the fixture's
# own status and that rule, not from $CLAUDE_LIMIT_TOKEN - asserting the
# variable against itself passes for any value, and this value has to
# match what run.py actually writes.
want_token="api_error_$(jq -r '.api_error_status' "$limit_fixture")"
claude_rate_limited "$want_token" \
  || { echo "FAIL: the bare token desloppify passes ($want_token) was missed"; fail=1; }
[ "$CLAUDE_LIMIT_TOKEN" = "$want_token" ] \
  || { echo "FAIL: CLAUDE_LIMIT_TOKEN is '$CLAUDE_LIMIT_TOKEN', but run.py composes '$want_token'"; fail=1; }

# --- what does not ---------------------------------------------------
# terminal_reason is "api_error" on a real limit AND on any other API
# failure, so it must not decide this by itself.
for status in 400 401 404 500 503 529; do
  claude_rate_limited "$(result_json api_error "{\"api_error_status\":$status}")" \
    && { echo "FAIL: HTTP $status read as a limit"; fail=1; }
done

# subtype is "success" on a real limit, so anything that matched reason
# words against subtype would read ordinary runs as limits.
for reason in $NON_LIMIT_REASONS; do
  claude_rate_limited "$reason" \
    && { echo "FAIL: '$reason' read as a limit"; fail=1; }
  claude_rate_limited "$(result_json "$reason" '{"subtype":"success"}')" \
    && { echo "FAIL: a '$reason' result object read as a limit"; fail=1; }
done

# The words the detector used to carry. Every one is either absent from
# the CLI and SDK entirely or belongs to an unrelated subsystem, so a
# run reporting one is NOT out of quota - and a stage editing this very
# repository can print any of them.
for dead in limit_reached quota_exceeded rate_limited rate_limit \
            usage_limit_reached insufficient_credits \
            credit_balance_too_low out_of_credits
do
  claude_rate_limited "$dead" \
    && { echo "FAIL: '$dead' is not an exhaustion signal but read as one"; fail=1; }
  claude_rate_limited "$(result_json "$dead")" \
    && { echo "FAIL: terminal_reason '$dead' read as a limit"; fail=1; }
done

# And the agent's own words, which live in .result - the field the
# detector never reads. The captured fixture's own result text is the
# strongest case: the real limit sentence, with no 429 beside it.
real_prose=$(jq -r '.result' "$limit_fixture")
claude_rate_limited "$(result_json completed "$(jq -cn --arg p "$real_prose" '{result:$p}')")" \
  && { echo "FAIL: the limit sentence in .result read as a limit"; fail=1; }
for prose in \
  "I edited rate_limit.go and asserted on 429 responses" \
  "VERDICT: NO-MERGE - the rate limit handling is untested"
do
  claude_rate_limited "$(result_json completed "$(jq -cn --arg p "$prose" '{result:$p}')")" \
    && { echo "FAIL: agent prose read as a limit: $prose"; fail=1; }
done

# --- the agent's prose is still readable -----------------------------
# stage-merge greps a VERDICT line out of the output, so .result has to
# survive the round trip intact, newlines and all.
got=$(claude_result_text "$(result_json completed "$(jq -cn '{result:"ANALYSIS: fine\n\nVERDICT: MERGE"}')")")
[ "$(printf '%s' "$got" | grep -oE '^VERDICT: (MERGE|NO-MERGE|RISKY)' | tail -1 | awk '{print $2}')" = "MERGE" ] \
  || { echo "FAIL: the VERDICT line did not survive .result extraction"; fail=1; }

# Non-JSON passes through, so a run that died before emitting a result
# object still logs whatever it did print.
[ "$(claude_result_text 'plain text, no json')" = "plain text, no json" ] \
  || { echo "FAIL: non-JSON output was not passed through"; fail=1; }

# --- account selection -----------------------------------------------
use_claude_account work || { echo "FAIL: work account not selectable"; fail=1; }
[ "$CLAUDE_CODE_OAUTH_TOKEN" = "work-token" ] || { echo "FAIL: wrong token for work"; fail=1; }
use_claude_account personal || { echo "FAIL: personal not selectable"; fail=1; }
[ "$CLAUDE_CODE_OAUTH_TOKEN" = "personal-token" ] || { echo "FAIL: wrong token for personal"; fail=1; }

# An API key must never survive selection: either key silently outranks
# the OAuth token and bills per token against the API account.
export ANTHROPIC_API_KEY=leaked
use_claude_account work
[ -z "${ANTHROPIC_API_KEY:-}" ] || { echo "FAIL: ANTHROPIC_API_KEY survived"; fail=1; }

# --- failover --------------------------------------------------------
attempt_log="$tmp/attempts"

: > "$attempt_log"
limited_cmd() { echo "$CLAUDE_ACCOUNT" >> "$attempt_log"; echo "$(jq -c . "$limit_fixture")"; return 1; }
run_with_account_failover limited_cmd >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 2 ] || { echo "FAIL: a limit did not retry"; fail=1; }
[ "$(head -1 "$attempt_log")" = "work" ] || { echo "FAIL: did not try work first"; fail=1; }
[ "$(tail -1 "$attempt_log")" = "personal" ] || { echo "FAIL: did not fail over to personal"; fail=1; }

: > "$attempt_log"
other_failure() { echo "$CLAUDE_ACCOUNT" >> "$attempt_log"; echo "$(result_json api_error '{"api_error_status":500}')"; return 1; }
run_with_account_failover other_failure >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 1 ] || { echo "FAIL: a non-limit failure burned the reserve"; fail=1; }

: > "$attempt_log"
ok_cmd() { echo "$CLAUDE_ACCOUNT" >> "$attempt_log"; echo "$(result_json completed)"; }
run_with_account_failover ok_cmd >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 1 ] || { echo "FAIL: a success was retried"; fail=1; }

# `timeout` killing a wedged run is not an exhausted account. Both the
# stages and the wrapper treat 124 as its own thing; without the
# exclusion a wedged run earns a second full timeout on the reserve.
: > "$attempt_log"
timed_out() { echo "$CLAUDE_ACCOUNT" >> "$attempt_log"; echo "$(jq -c . "$limit_fixture")"; return 124; }
run_with_account_failover timed_out >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 1 ] || { echo "FAIL: a timeout burned the reserve"; fail=1; }

# --- the prompt must survive the retry -------------------------------
# The retry has to see the SAME prompt as the first attempt. It did not:
# every stage wrote `out=$(run_with_account_failover ... < prompt.txt)`,
# which attaches the redirect to the whole function, so attempt 1 read
# stdin to EOF and attempt 2 ran the agent with ZERO BYTES. The failover
# fired, spent the reserve on an empty prompt, and would have parked the
# card anyway.
#
# The fake READS STDIN, which is the point: this suite missed the bug
# because none of its fakes did. It reads with `read -t` rather than
# `cat` because an unbounded read blocks on the runner's own stdin if
# the wrapper stops redirecting, and the suite then HANGS instead of
# failing - a hang reports nothing in CI.
prompt_file="$tmp/prompt.txt"
printf 'ticket ABC-123\nimplement the thing\n' > "$prompt_file"
# Counted the way the fake reads it (line bodies, no separators), so the
# expectation is derived from the fixture rather than written down.
want_bytes=$(awk '{ n += length($0) } END { print n+0 }' "$prompt_file")

stdin_reader() {
  local p="" line
  while IFS= read -r -t 5 line; do p="$p$line"; done
  printf '%s %s\n' "$CLAUDE_ACCOUNT" "${#p}" >> "$attempt_log"
  [ "$CLAUDE_ACCOUNT" = "work" ] && { echo "$(jq -c . "$limit_fixture")"; return 1; }
  echo "$(result_json completed)"
}

: > "$attempt_log"
run_with_account_failover --stdin "$prompt_file" stdin_reader >/dev/null 2>&1
[ "$(wc -l < "$attempt_log")" -eq 2 ] \
  || { echo "FAIL: --stdin did not retry on a limit"; fail=1; }
while read -r acct bytes; do
  [ "$bytes" = "$want_bytes" ] \
    || { echo "FAIL: the $acct attempt got $bytes prompt bytes, want $want_bytes"; fail=1; }
done < "$attempt_log"

# --- missing tokens --------------------------------------------------
rm -f "$CLAUDE_TOKEN_DIR/oauth-token"
: > "$attempt_log"
run_with_account_failover ok_cmd >/dev/null 2>&1
[ "$(cat "$attempt_log")" = "personal" ] || { echo "FAIL: no work token should fall straight to personal"; fail=1; }

rm -f "$CLAUDE_TOKEN_DIR/oauth-token-personal"

# A pod with no mounted token must still pass if the CLI has its own
# login. The session pods authenticate that way and have no
# /run/secrets/claude mount; refusing them would stop all three stages.
export HOME="$tmp/home"
mkdir -p "$HOME/.claude"
printf '{"claudeAiOauth":{}}' > "$HOME/.claude/.credentials.json"
preflight_credential >/dev/null 2>&1 || { echo "FAIL: refused a pod that has the CLI's own login"; fail=1; }

rm -f "$HOME/.claude/.credentials.json"
preflight_credential >/dev/null 2>&1 && { echo "FAIL: passed with no tokens and no CLI login"; fail=1; }

# --- every stage must go through the wrapper -------------------------
# This suite passed for weeks while all three stages invoked `claude -p`
# bare, because it only ever exercised the helper directly. The library
# said as much in prose, and prose does not fail a build.
#
# Checked on the LOGICAL command - comments stripped, backslash
# continuations joined - because an earlier version checked line
# adjacency and certified an unwired stage.
for stage in stage-author stage-test stage-merge; do
  f="$here_dir/../$stage.sh"
  [ -f "$f" ] || { echo "FAIL: cannot find $stage.sh to check"; fail=1; continue; }
  # Join backslash continuations, then strip comments. The previous
  # form of this (tr to \001, sed, tr back) did NOT join anything - the
  # substitution never matched - so a gate documented as checking the
  # logical command was still matching line adjacency, the very defect
  # it was written to replace. Verified by hand on a three-line
  # continuation before and after.
  joined=$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$f" | sed 's/#.*//')

  printf '%s' "$joined" | grep -q 'run_with_account_failover' \
    || { echo "FAIL: $stage.sh does not call run_with_account_failover"; fail=1; }

  # A bare `claude -p` anywhere in the stage is the bug returning.
  printf '%s' "$joined" | grep -E 'claude -p' | grep -qv 'run_with_account_failover' \
    && { echo "FAIL: $stage.sh invokes claude -p outside the wrapper"; fail=1; }

  # The prompt goes through --stdin. A redirect around the wrapper is
  # the drained-stdin bug, and it is invisible in a diff that still
  # shows a prompt file being passed.
  printf '%s' "$joined" | grep -qE 'run_with_account_failover[^|&;]*<[[:space:]]*"?\$' \
    && { echo "FAIL: $stage.sh redirects into run_with_account_failover; pass --stdin"; fail=1; }
  printf '%s' "$joined" | grep -q 'run_with_account_failover --stdin' \
    || { echo "FAIL: $stage.sh does not pass its prompt with --stdin"; fail=1; }

  # Detection needs the JSON, so every stage has to ask for it.
  printf '%s' "$joined" | grep -q 'output-format json' \
    || { echo "FAIL: $stage.sh does not pass --output-format json"; fail=1; }
done

# --- desloppify shares this library ----------------------------------
# The desloppify image COPYs lib/claude-account.sh and calls the
# detector with a BARE reason word (`jq -r .stop_reason`), not a result
# object. Every reason is already covered in both forms above; what is
# pinned here is that its call shape still exists in the script, so a
# change made for the stages cannot quietly drop it.
nd="$here_dir/../../desloppify-pod/nightly-desloppify.sh"
if [ -f "$nd" ]; then
  # -F: the pattern contains $( and ., which as a regex matched nothing
  # and made this gate pass vacuously on first write.
  grep -qF 'claude_rate_limited "$(jq -r' "$nd" \
    || { echo "FAIL: nightly-desloppify.sh no longer passes a bare jq-extracted reason"; fail=1; }
else
  echo "FAIL: cannot find nightly-desloppify.sh to check its call shape"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS - work first, personal only when out of quota, no key leak, CLI login honoured, nothing-at-all refused, prompt survives the retry, and all three stages go through the wrapper with JSON output"
exit "$fail"
