#!/usr/bin/env bash
# kbrowser — drive agent-browser against a Kernel cloud browser (kernel.sh).
#
# Why this exists: this pod has no Chrome and no display (and no root to add
# either). Kernel hosts the browser in its cloud; agent-browser connects out
# over CDP. Headless by default (~$0.06/hr); `--headed` runs a headful session
# and prints a live-view URL you open on your LAPTOP to watch in real time
# (~$0.48/hr). Free tier = $5/mo credits, 5 concurrent browsers.
#
#   kbrowser up [--headed]   create a Kernel session + connect agent-browser
#   kbrowser status          show the active session
#   kbrowser run -- ARGS     run `agent-browser ARGS` against the session
#   kbrowser down            delete the Kernel session (stop billing)
#
# Key resolution: $KERNEL_API_KEY, else ~/.config/kernel/api-key (chmod 600).
set -euo pipefail

API="https://api.onkernel.com"
STATE="${XDG_CACHE_HOME:-$HOME/.cache}/kernel/session.json"
KEYFILE="${XDG_CONFIG_HOME:-$HOME/.config}/kernel/api-key"

die() { echo "kbrowser: $*" >&2; exit 1; }

load_key() {
  [ -n "${KERNEL_API_KEY:-}" ] && return
  [ -r "$KEYFILE" ] && { KERNEL_API_KEY="$(tr -d '\r\n' < "$KEYFILE")"; return; }
  die "no KERNEL_API_KEY in env and no key file at $KEYFILE"
}

cdp_url() { [ -r "$STATE" ] || die "no active session (run: kbrowser up)"; jq -r '.cdp_ws_url' "$STATE"; }

cmd_up() {
  load_key
  local headless=true
  [ "${1:-}" = "--headed" ] && headless=false
  mkdir -p "$(dirname "$STATE")"
  local resp; resp="$(curl -fsS -X POST "$API/browsers" \
    -H "Authorization: Bearer $KERNEL_API_KEY" -H "Content-Type: application/json" \
    -d "{\"headless\":$headless,\"stealth\":true,\"timeout_seconds\":300}")" \
    || die "create failed (check API key / free-tier concurrency)"
  echo "$resp" > "$STATE"
  local sid cdp lv
  sid="$(jq -r '.session_id' <<<"$resp")"
  cdp="$(jq -r '.cdp_ws_url' <<<"$resp")"
  lv="$(jq -r '.browser_live_view_url // empty' <<<"$resp")"
  echo "session $sid (headless=$headless)"
  # Try a persistent connection; fall back to per-command --cdp in `run`.
  agent-browser connect "$cdp" >/dev/null 2>&1 && echo "agent-browser connected (persistent)" \
    || echo "note: persistent connect unavailable — use 'kbrowser run -- ...'"
  [ -n "$lv" ] && echo "LIVE VIEW (open on your laptop): $lv"
  return 0
}

cmd_run()    { local c; c="$(cdp_url)"; shift_dashdash "$@"; agent-browser --cdp "$c" "${RUNARGS[@]}"; }
shift_dashdash() { RUNARGS=(); local seen=0; for a in "$@"; do [ "$a" = "--" ] && { seen=1; continue; }; [ "$seen" = 1 ] && RUNARGS+=("$a"); done; [ "${#RUNARGS[@]}" -gt 0 ] || die "usage: kbrowser run -- <agent-browser args>"; }

cmd_status() { [ -r "$STATE" ] && jq '{session_id,headless,cdp_ws_url,browser_live_view_url}' "$STATE" || echo "no active session"; }

cmd_down() {
  load_key
  [ -r "$STATE" ] || { echo "no active session"; return 0; }
  local sid; sid="$(jq -r '.session_id' "$STATE")"
  curl -fsS -X DELETE "$API/browsers/$sid" -H "Authorization: Bearer $KERNEL_API_KEY" >/dev/null \
    && echo "deleted $sid" || echo "delete returned non-zero (may already be gone)"
  agent-browser close >/dev/null 2>&1 || true
  rm -f "$STATE"
}

case "${1:-}" in
  up)     shift; cmd_up "$@";;
  run)    shift; cmd_run "$@";;
  status) cmd_status;;
  down)   cmd_down;;
  *) echo "usage: kbrowser {up [--headed]|run -- <args>|status|down}"; exit 1;;
esac
