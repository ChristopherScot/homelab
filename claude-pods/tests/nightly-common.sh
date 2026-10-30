#!/usr/bin/env bash
# Regression test for issue #59: the three nightly scripts each carried
# their own copy of pick_model, render_prompt, cred_ok,
# preflight_credential, the GitHub token check and the Loki tee, and the
# copies drifted — a fix landed in one pod and not the others. They now
# share lib/nightly-common.sh. This checks that the sharing is real:
#
#   1. the library sources cleanly and silently, and defines every
#      function the scripts call;
#   2. each entry point sources NIGHTLY_LIB before doing anything else,
#      so a fix in the library reaches all three pods;
#   3. no entry point still carries a private copy of a library function
#      or of the tee block;
#   4. the image places the library where the scripts' default
#      NIGHTLY_LIB points.
#
# Run: claude-pods/tests/nightly-common.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
pods="$here/.."
lib="$pods/lib/nightly-common.sh"
scripts=(nightly-author nightly-test nightly-merge)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

for f in "$lib" "${scripts[@]/#/$pods/}"; do
  f="${f%.sh}.sh"
  bash -n "$f" || fail "$f does not parse"
done

# 1. Sourcing defines the shared functions and has no other effect: no
#    output, no exit, under the same `set -u` the scripts run with.
out=$(bash -uo pipefail -c '
  source "$1" || exit 1
  for fn in pick_model render_prompt log_to require_gh_token cred_ok preflight_credential; do
    declare -F "$fn" >/dev/null || { echo "missing $fn"; exit 1; }
  done
  [ -n "${MODEL:-}" ] && [ -n "${PROMPT_DIR:-}" ] && [ -n "${STATE_DIR:-}" ] && [ -n "${OWNER:-}" ] \
    || { echo "shared defaults not set"; exit 1; }
' _ "$lib" 2>&1) || fail "library did not source cleanly: $out"
[ -z "$out" ] || fail "sourcing the library printed something: $out"

# 2. Every entry point reaches the library first. A stand-in library that
#    announces itself and exits proves both: had the script done anything
#    of its own before sourcing — the tee, the token check — that would
#    show in the output or the exit status instead.
#    The stand-in uses only shell builtins, because the script runs with
#    NO external commands available: a script that does not source it
#    runs for real, and on a session pod that means a live GitHub token,
#    a working kubectl and this very clone being checked out and reset
#    under whoever is using it (this happened). With an empty PATH an
#    unconverted script dies at its first `date` or `mkdir`, touching
#    nothing — and the property under test is stated exactly: nothing but
#    builtins runs before the library is sourced.
printf '%s\n' 'echo "sourced by ${0##*/}"' 'exit 0' > "$tmp/stub.sh"
for s in "${scripts[@]}"; do
  out=$(env -i NIGHTLY_LIB="$tmp/stub.sh" PATH=/nonexistent "$BASH" "$pods/$s.sh" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "sourced by $s.sh" ] \
    || fail "$s.sh did not source NIGHTLY_LIB before doing anything else (rc=$rc): $out"
done

# 3. No private copies left behind: that is the drift the issue is about.
mapfile -t fns < <(grep -oE '^[a-z_]+\(\)' "$lib" | tr -d '()')
[ "${#fns[@]}" -ge 6 ] || fail "expected the library to define at least 6 functions, found ${#fns[@]}"
for s in "${scripts[@]}"; do
  for fn in "${fns[@]}"; do
    grep -qE "^${fn}\(\)" "$pods/$s.sh" && fail "$s.sh still defines its own $fn"
  done
  grep -q '/proc/1/fd/1' "$pods/$s.sh" && fail "$s.sh still carries its own copy of the Loki tee block"
done

# 4. The default NIGHTLY_LIB in each script is a path the image populates.
for s in "${scripts[@]}"; do
  default=$(sed -nE 's/.*NIGHTLY_LIB:-([^}]+)\}.*/\1/p' "$pods/$s.sh" | head -1)
  [ -n "$default" ] || fail "$s.sh has no NIGHTLY_LIB default"
  [ "$(basename "$default")" = "$(basename "$lib")" ] \
    || fail "$s.sh defaults NIGHTLY_LIB to $default, not to $(basename "$lib")"
  grep -qE "^COPY lib/ +$(dirname "$default")/?$" "$pods/Dockerfile" \
    || fail "Dockerfile does not COPY lib/ to $(dirname "$default"), where $s.sh looks for it"
done

echo "PASS: lib/nightly-common.sh sources cleanly, all three nightly scripts source it first, none keeps a private copy, and the image ships it where they look"
