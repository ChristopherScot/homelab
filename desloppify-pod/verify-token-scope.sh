#!/usr/bin/env bash
# What the desloppify PAT can and cannot do, measured rather than assumed.
#
# Reads the token from a file given as $1, so it never appears in argv,
# the environment of another process, or a shell history.
#
# Nothing here writes to main. The destructive-sounding checks are all
# dry runs: the merge test is the one case where a real attempt is the
# only honest answer, and it is left to a human to run deliberately with
# a throwaway PR. See MERGE TEST at the bottom.
set -uo pipefail

REPO="${DESLOP_REPO:-schoolhouse-world/app}"
TOKEN_FILE="${1:-}"

if [ -z "$TOKEN_FILE" ] || [ ! -r "$TOKEN_FILE" ]; then
  echo "usage: $0 <path-to-token-file>" >&2
  exit 2
fi

GH_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
export GH_TOKEN
if [ -z "$GH_TOKEN" ]; then echo "FATAL: token file is empty" >&2; exit 2; fi
unset GITHUB_TOKEN   # gh prefers GITHUB_TOKEN when both are set

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }

echo "=== desloppify PAT scope, against $REPO ==="
echo

# --- identity -------------------------------------------------------
echo "identity"
who=$(gh api user --jq .login 2>/dev/null)
if [ -n "$who" ]; then note "authenticates as: $who"; else
  bad "token does not authenticate at all"; echo; echo "aborting"; exit 1
fi

# --- the repo is reachable, and only it ------------------------------
echo
echo "repository access"
if gh api "repos/$REPO" --jq .full_name >/dev/null 2>&1; then
  ok "can see $REPO"
else
  bad "cannot see $REPO - the token is scoped to the wrong repo or needs org approval"
fi

# Write access, not visibility, is what scopes a token. Any authenticated
# token can read metadata for repositories the user can see, so a read
# test reports a failure that is not one. Probing a write that must be
# refused is the question worth asking.
elsewhere="${DESLOP_SCOPE_PROBE_REPO:-ChristopherScot/homelab}"
other_sha=$(gh api "repos/$elsewhere/git/ref/heads/main" --jq .object.sha 2>/dev/null)
if [ -z "$other_sha" ]; then
  note "skipped the cross-repo write probe ($elsewhere not readable)"
elif gh api "repos/$elsewhere/git/refs" -X POST \
       -f ref="refs/heads/desloppify-scope-probe-$$" -f sha="$other_sha" >/dev/null 2>&1; then
  bad "CAN write to $elsewhere - the token is not limited to $REPO"
  note "delete refs/heads/desloppify-scope-probe-$$ in $elsewhere by hand"
else
  ok "cannot write to $elsewhere - write access is limited to $REPO"
fi

# --- THE ONE THAT MATTERS: no Administration -------------------------
echo
echo "administration scope (must be absent)"
code=$(gh api "repos/$REPO/branches/main/protection" \
         --silent --include 2>/dev/null | head -1 | grep -oE '[0-9]{3}' | head -1)
if [ "$code" = "403" ] || [ "$code" = "404" ]; then
  ok "cannot read main's branch protection (HTTP $code) - no Administration scope"
else
  bad "CAN read main's branch protection (HTTP ${code:-?}) - token is OVER-SCOPED"
  note "remove the Administration permission and regenerate"
fi

# --- can it do its actual job? ---------------------------------------
echo
echo "the permissions the pod needs"
if gh api "repos/$REPO/contents/package.json" --jq .name >/dev/null 2>&1; then
  ok "Contents: read"
else
  bad "cannot read repository contents"
fi

if gh api "repos/$REPO/pulls?state=open&per_page=1" >/dev/null 2>&1; then
  ok "Pull requests: read"
else
  bad "cannot list pull requests"
fi

# Write, probed without creating anything: a head branch that does not
# exist is rejected 422 when the token may open PRs and 403 when it may
# not. Reading .permissions instead would report the USER's role in the
# repo, which says nothing about what the token was granted.
pr_code=$(gh api "repos/$REPO/pulls" -X POST \
            -f title="scope probe" -f head="desloppify-nonexistent-probe-$$" \
            -f base="main" --silent --include 2>/dev/null \
            | head -1 | grep -oE '[0-9]{3}' | head -1)
case "$pr_code" in
  422) ok "Pull requests: write (rejected on a bad ref, not on permission)" ;;
  403) bad "Pull requests: WRITE IS MISSING (HTTP 403) - the pod cannot open PRs"
       note "set Pull requests to Read and write, and check for a pending"
       note "org approval at /settings/personal-access-token-requests" ;;
  201) bad "a pull request was actually created - delete it"
       note "the probe branch unexpectedly existed" ;;
  *)   bad "unexpected response probing PR write: HTTP ${pr_code:-?}" ;;
esac

# Write is confirmed by creating and immediately deleting a ref that no
# protection rule covers. If the delete fails the ref is reported so it
# can be removed by hand.
probe="refs/heads/desloppify-scope-probe-$$"
base=$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha 2>/dev/null)
if [ -n "$base" ]; then
  if gh api "repos/$REPO/git/refs" -X POST \
       -f ref="$probe" -f sha="$base" >/dev/null 2>&1; then
    ok "Contents: write (created a scratch branch)"
    if gh api "repos/$REPO/git/$probe" -X DELETE >/dev/null 2>&1; then
      note "scratch branch removed"
    else
      bad "could not delete the scratch branch: $probe"
      note "remove it by hand"
    fi
  else
    bad "cannot create a branch - Contents:write is missing"
  fi
else
  note "could not read main's sha; skipped the write probe"
fi

# --- what it must NOT be able to do ----------------------------------
echo
echo "permissions the pod must not have"
for check in \
  "Workflows:actions/workflows" \
  "Secrets:actions/secrets" \
  "Environments:environments" \
  "Deployments:deployments"
do
  label="${check%%:*}"; path="${check#*:}"
  if gh api "repos/$REPO/$path" >/dev/null 2>&1; then
    bad "$label is readable - more scope than the pod needs"
  else
    ok "$label not accessible"
  fi
done

if gh api "repos/$REPO" -X PATCH -f has_issues=true >/dev/null 2>&1; then
  bad "can modify repository settings - Administration scope is present"
else
  ok "cannot modify repository settings"
fi

# --- summary ---------------------------------------------------------
echo
echo "=== $pass passed, $fail failed ==="
echo
cat <<'MERGE'
MERGE TEST (run by hand, deliberately)

This script does not try to merge into main. The protection JSON shows
bypass_pull_request_allowances granting the Engineering team the right to
bypass review, and whether a fine-grained PAT inherits that is not
answerable by reading settings - only by trying.

To settle it, with a PR you are willing to close:

  1. Open a throwaway PR against main from a scratch branch.
  2. With GH_TOKEN set to THIS token, run:
         gh pr merge <n> --repo schoolhouse-world/app --squash
  3. It must fail. If it succeeds, close/revert immediately and treat the
     PAT as insufficient on its own - the tool policy becomes the only
     thing standing between the pod and main.

Do this once, before the pod runs unattended.
MERGE

[ "$fail" -eq 0 ] || exit 1
