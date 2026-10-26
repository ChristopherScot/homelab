#!/usr/bin/env bash
# Log in to Claude on one pod, then copy the credential to every other pod.
#
# The OAuth credential is a plain token pair with no device or host
# binding, so one interactive login covers the whole StatefulSet. That
# matters because the alternative — logging in per pod — scales with
# replica count and each login burns a browser round-trip.
#
# Pods are discovered by label, so this works for 2 pods or 20.
#
#   ./scripts/claude-pods-login.sh
#
# Run it when auth breaks everywhere at once: a revoked session, or a
# refresh that writes a corrupt expiresAt (seen in the wild as 0, which
# Claude Code reads as "expired in 1970" and cannot recover from).
set -uo pipefail

NS="${CLAUDE_PODS_NS:-claude-pods}"
SELECTOR="${CLAUDE_PODS_SELECTOR:-app=claude-session}"
CRED=".claude/.credentials.json"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"

# Plain array append rather than mapfile: macOS ships bash 3.2, where
# mapfile does not exist and this script would die on its first line.
PODS=()
while IFS= read -r line; do
  [ -n "$line" ] && PODS+=("$line")
done < <(kubectl get pods -n "$NS" -l "$SELECTOR" \
  --field-selector status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
[ "${#PODS[@]}" -gt 0 ] || die "no running pods matching $SELECTOR in $NS"

say "Pods: ${PODS[*]}"

# Log in on whichever pod is first; the credential is identical either way.
LOGIN_POD="${CLAUDE_LOGIN_POD:-${PODS[0]}}"
say "Logging in on $LOGIN_POD"

kubectl exec -n "$NS" "$LOGIN_POD" -- sh -c '
  tmux kill-session -t login 2>/dev/null
  tmux new-session -d -s login -c /workspace -x 200 -y 50 "claude"
' 2>/dev/null || die "could not start a login session on $LOGIN_POD"

# Wait for the TUI, then drive /login and pick the subscription option.
# Option 1 is "Claude account with subscription" — the Console option
# would bill per token instead of using the existing plan.
sleep 12
kubectl exec -n "$NS" "$LOGIN_POD" -- tmux send-keys -t login "/login" 2>/dev/null
sleep 2
kubectl exec -n "$NS" "$LOGIN_POD" -- tmux send-keys -t login Enter 2>/dev/null
sleep 8
kubectl exec -n "$NS" "$LOGIN_POD" -- tmux send-keys -t login Enter 2>/dev/null

# The URL wraps across pane columns, so rejoin it rather than printing the
# pane as-is — a wrapped URL is not clickable and silently loses characters.
url=""
for _ in $(seq 1 20); do
  url=$(kubectl exec -n "$NS" "$LOGIN_POD" -- tmux capture-pane -p -t login 2>/dev/null \
    | tr -d '\r' \
    | awk '/https:\/\/claude\.com\/cai\/oauth/{f=1} f&&/Paste code here/{f=0} f' \
    | tr -d '\n' | sed 's/^ *//')
  url="${url#*https}"
  [ -n "$url" ] && { url="https$url"; break; }
  sleep 3
done
[ -n "$url" ] || die "no login URL appeared; attach with: kubectl exec -it -n $NS $LOGIN_POD -- tmux attach -t login"

cat <<BANNER

────────────────────────────────────────────────────────────────────────
Open this, approve, and copy the code it gives you back:

$url

────────────────────────────────────────────────────────────────────────
BANNER

printf 'Paste the code here: '
read -r code
[ -n "$code" ] || die "no code entered"

# -l sends the string literally: the code contains a '#', which tmux would
# otherwise treat as the start of a format specifier.
kubectl exec -n "$NS" "$LOGIN_POD" -- tmux send-keys -t login -l "$code" 2>/dev/null
sleep 2
kubectl exec -n "$NS" "$LOGIN_POD" -- tmux send-keys -t login Enter 2>/dev/null

say ""
say "Waiting for the credential to be written..."
ok=false
for _ in $(seq 1 20); do
  if kubectl exec -n "$NS" "$LOGIN_POD" -- sh -c "[ -s \"\$HOME/$CRED\" ]" 2>/dev/null; then
    # Written is not the same as valid: a corrupt expiresAt is exactly the
    # failure this script exists to repair, so do not propagate one.
    if kubectl exec -n "$NS" "$LOGIN_POD" -- node -e '
      const d=require(process.env.HOME+"/.claude/.credentials.json").claudeAiOauth;
      if (!d || !d.accessToken || !(d.expiresAt > Date.now())) process.exit(1);
    ' 2>/dev/null; then ok=true; break; fi
  fi
  sleep 3
done
$ok || die "login did not produce a valid credential on $LOGIN_POD"

say "Login OK on $LOGIN_POD"
kubectl exec -n "$NS" "$LOGIN_POD" -- tmux kill-session -t login 2>/dev/null || true

# Identity block lives in .claude.json, separate from the token file; both
# are needed or the pod authenticates but shows no account.
oauth=$(kubectl exec -n "$NS" "$LOGIN_POD" -- \
  node -e 'process.stdout.write(JSON.stringify(require(process.env.HOME+"/.claude.json").oauthAccount||{}))' 2>/dev/null)

fails=0
for pod in "${PODS[@]}"; do
  [ "$pod" = "$LOGIN_POD" ] && continue
  say "Copying credential -> $pod"

  if ! kubectl exec -n "$NS" "$LOGIN_POD" -- cat "/home/node/$CRED" 2>/dev/null \
     | kubectl exec -i -n "$NS" "$pod" -- sh -c "umask 077; mkdir -p \"\$HOME/.claude\"; cat > \"\$HOME/$CRED\"" 2>/dev/null; then
    say "  FAILED to copy to $pod"
    fails=$((fails+1))
    continue
  fi

  if [ -n "$oauth" ] && [ "$oauth" != "{}" ]; then
    printf '%s' "$oauth" \
      | kubectl exec -i -n "$NS" "$pod" -- sh -c 'cat > /tmp/oa.json' 2>/dev/null
    kubectl exec -n "$NS" "$pod" -- node -e '
      const fs=require("fs"), f=process.env.HOME+"/.claude.json";
      const d=JSON.parse(fs.readFileSync(f,"utf8"));
      d.oauthAccount=JSON.parse(fs.readFileSync("/tmp/oa.json","utf8"));
      fs.writeFileSync(f, JSON.stringify(d,null,2));
    ' 2>/dev/null
    kubectl exec -n "$NS" "$pod" -- rm -f /tmp/oa.json 2>/dev/null
  fi
done

say ""
say "Verifying every pod can authenticate:"
for pod in "${PODS[@]}"; do
  out=$(kubectl exec -n "$NS" "$pod" -- sh -c \
    'cd /workspace && timeout 120 claude -p --model opus "Reply with exactly: OK" 2>&1 | tail -1' 2>/dev/null)
  case "$out" in
    *OK*) say "  $pod: ok" ;;
    *)    say "  $pod: FAILED — $out"; fails=$((fails+1)) ;;
  esac
done

say ""
if [ "$fails" -eq 0 ]; then
  say "All ${#PODS[@]} pods authenticated."
else
  die "$fails pod(s) did not authenticate"
fi
