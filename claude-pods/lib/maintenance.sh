#!/usr/bin/env bash
# Best-effort cache maintenance. The Go worker holds the pod lock and waits
# for its supervised tool groups to exit before invoking prune.
HOME_TIGHT_PCT="${HOME_TIGHT_PCT:-85}"

home_usage() {
  df -P "$HOME" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

warn_if_home_tight() {
  local pct
  pct=$(home_usage)
  [[ "$pct" =~ ^[0-9]+$ ]] || return 0
  if [ "$pct" -ge "$HOME_TIGHT_PCT" ]; then
    echo "WARNING: home disk is $pct% full; Claude may run out of space" >&2
  fi
}

prune_build_caches() {
  local pct
  pct=$(home_usage)
  [[ "$pct" =~ ^[0-9]+$ ]] || return 0
  [ "$pct" -ge "$HOME_TIGHT_PCT" ] || return 0
  if command -v go >/dev/null 2>&1; then
    go clean -modcache >/dev/null 2>&1 || true
    go clean -cache >/dev/null 2>&1 || true
  fi
  if command -v npm >/dev/null 2>&1; then
    npm cache clean --force >/dev/null 2>&1 || true
  fi
  echo "requested cache cleanup after home disk reached $pct%"
}

case "${1:-}" in
  warn) warn_if_home_tight ;;
  prune) prune_build_caches ;;
  *) echo 'usage: maintenance.sh warn|prune' >&2; exit 2 ;;
esac
