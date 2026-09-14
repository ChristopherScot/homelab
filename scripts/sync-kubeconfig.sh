#!/usr/bin/env bash
# Refresh the local kubeconfig from the k3s node.
#
# Why this exists: k3s auto-renews the admin client cert embedded in
# /etc/rancher/k3s/k3s.yaml, but only when the server restarts and only
# once the cert is within 90 days of expiring. The copy on this Mac does
# NOT follow along, so it silently goes stale and the next kubectl fails
# with a confusing "You must be logged in to the server (401)" — or, if
# the host also resolves to a dead Tailscale IP, an i/o timeout that
# looks like the node is down. (Happened 2026-09-13: the node rotated on
# a 10:20 restart, the laptop copy had expired back on Aug 16.)
#
# Only the client cert rotates on a human timescale; the CA is a 10-year
# cert. So this just re-pulls the whole kubeconfig — simpler than trying
# to splice one field, and idempotent.
#
# Usage:
#   scripts/sync-kubeconfig.sh          # refresh if the local copy differs
#   scripts/sync-kubeconfig.sh --check  # report only, change nothing
set -euo pipefail

SSH_HOST="${HOMELAB_SSH_HOST:-homelab}"
# The node's kubeconfig says 127.0.0.1, which is only right *on* the node.
# Rewrite it to an address this machine can reach. Override if the LAN IP
# changes: KUBE_SERVER=https://host:6443 scripts/sync-kubeconfig.sh
SERVER="${KUBE_SERVER:-https://192.168.50.179:6443}"
DEST="${KUBECONFIG_DEST:-$HOME/.kube/config}"

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

cert_enddate() {
  # Reads a kubeconfig on stdin, prints the client cert's expiry.
  grep client-certificate-data | awk '{print $2}' | base64 -d \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2
}

if [ -f "$DEST" ]; then
  local_end=$(cert_enddate < "$DEST" || true)
  if [ -n "$local_end" ]; then
    if openssl x509 -checkend 0 -noout \
        -in <(grep client-certificate-data "$DEST" | awk '{print $2}' | base64 -d) >/dev/null 2>&1; then
      echo "local:  valid until $local_end"
    else
      echo "local:  EXPIRED $local_end"
    fi
  else
    echo "local:  no client cert found in $DEST"
  fi
else
  echo "local:  $DEST does not exist"
fi

remote=$(ssh -o BatchMode=yes "$SSH_HOST" 'cat /etc/rancher/k3s/k3s.yaml')
if [ -z "$remote" ]; then
  echo "error: could not read kubeconfig from $SSH_HOST" >&2
  exit 1
fi
echo "remote: valid until $(printf '%s' "$remote" | cert_enddate)"

new=$(printf '%s' "$remote" | sed "s|https://127.0.0.1:6443|$SERVER|")

# Compare full content, not dates: k3s renews by extending notAfter on the
# same cert, so notBefore never moves and can't be used as a change signal.
if [ -f "$DEST" ] && [ "$new" = "$(cat "$DEST")" ]; then
  echo "in sync: $DEST already matches the node"
  exit 0
fi

if [ "$check_only" = 1 ]; then
  echo "OUT OF SYNC: $DEST differs from the node (run without --check to update)"
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
[ -f "$DEST" ] && cp "$DEST" "$DEST.bak.$(date +%Y%m%d%H%M%S)"
printf '%s' "$new" > "$DEST.tmp"
chmod 600 "$DEST.tmp"
mv "$DEST.tmp" "$DEST"
echo "updated $DEST (server $SERVER; previous copy saved as $DEST.bak.*)"
