#!/usr/bin/env bash
# Make wifi a true BACKUP for the wired link: Ethernet always, wifi only
# when Ethernet is unavailable - with the node keeping ONE IP either way.
#
# Why this exists (2026-11-10): the nodes ran wired + wifi dual-active on
# one subnet. Linux routes by destination only and strict rp_filter
# drops the resulting asymmetric replies, so long-lived flows (1.6GB
# image pulls, twice that day) black-holed whenever route preference
# flipped. Separately, the wifi->wired migration changed every node's
# IP, which broke MetalLB announcements, Synology export rules, and
# vault. Both failure classes need the same cure: one interface active
# at a time, one address forever.
#
# The trick: the wifi profile is reconfigured to claim the SAME static
# IP as the wired profile, autoconnect off. Two mechanisms keep the
# level invariant "wifi up exactly when wired is down":
#   - a NetworkManager dispatcher script reacts to wired down/up EVENTS
#     within a second (the fast path), and
#   - a systemd timer reconciles the LEVEL every 2 minutes - covering
#     the cases events cannot: a cold boot with the wired link already
#     dead (no down event ever fires), an AP bounce while running on
#     wifi (autoconnect is off, nothing else retries), or any missed
#     edge. Same events-plus-reconcile shape as the kaneo dispatcher.
# The node's address never changes, so k3s registration, MetalLB,
# flannel and NFS export rules see nothing; a failover is a few seconds
# of retransmits inside existing TCP connections.
# (The kernel-native alternative - an active-backup bond - was rejected:
# wifi slaves need fail_over_mac juggling and driver cooperation.)
#
# Run AS ROOT on each node, over the WIRED connection:
#
#   sudo bash bootstrap/wifi-backup.sh --detect-only   # preview choices
#   sudo bash bootstrap/wifi-backup.sh --yes           # apply
#
# Overrides when detection picks wrong: --wired-dev DEV --wifi-con NAME.
#
# NOTE: the static wired config is written but NOT exercised until the
# next activation (NM refuses live dhcp->manual reapply), so test it
# deliberately rather than discovering it on an unplanned reboot.
# Test failover WITHOUT risking a stranded node: schedule a dead-man
# restore first, then drop the wired link -
#
#   sudo systemd-run --on-active=90 nmcli con up "<wired con>"
#   sudo nmcli dev disconnect <wired dev>
#   # watch: wifi comes up holding the same IP; ssh survives.
#   sudo nmcli con up "<wired con>"   # or let the dead-man do it
#
# A software disconnect exercises the dispatcher; a real cable pull
# additionally proves carrier detection - do one of those too.
set -euo pipefail

say() { printf '%s\n' "$*"; }
die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

YES=no; DETECT_ONLY=no; WIRED_DEV=""; WIFI_CON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=yes ;;
    --detect-only) DETECT_ONLY=yes ;;
    --wired-dev) WIRED_DEV="$2"; shift ;;
    --wifi-con) WIFI_CON="$2"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
command -v nmcli >/dev/null || die "NetworkManager (nmcli) not found - this node needs a different recipe"

# Report which phase died and how to recover, instead of a silent
# partial apply (the dual-active hazard persisting silently is worse
# than the script failing).
PHASE=detect
trap 'rc=$?; [ $rc -ne 0 ] && printf "FAILED during phase: %s\nRecover: re-run after fixing the cause; every step is idempotent.\nIf wired is static but wifi untouched, dual-active may persist - check: nmcli dev status\n" "$PHASE" >&2' EXIT

# --- detect ---------------------------------------------------------------
if [ -z "$WIRED_DEV" ]; then
  ETH_COUNT=$(nmcli -t -f DEVICE,TYPE,STATE dev status | awk -F: '$2=="ethernet" && $3=="connected"' | wc -l)
  [ "$ETH_COUNT" -le 1 ] || die "multiple connected ethernet devices - pass --wired-dev explicitly:
$(nmcli -t -f DEVICE,TYPE,STATE dev status | awk -F: '$2=="ethernet" && $3=="connected" {print "  " $1}')"
  WIRED_DEV=$(nmcli -t -f DEVICE,TYPE,STATE dev status | awk -F: '$2=="ethernet" && $3=="connected" {print $1; exit}')
fi
[ -n "$WIRED_DEV" ] || die "no connected ethernet device - bring the wired link up first"
WIRED_CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$WIRED_DEV" '$2==d {print $1; exit}')
[ -n "${WIRED_CON:-}" ] || die "no active connection on $WIRED_DEV"

WIFI_DEV=$(nmcli -t -f DEVICE,TYPE dev status | awk -F: '$2=="wifi" {print $1; exit}')
[ -n "${WIFI_DEV:-}" ] || die "no wifi device - nothing to make a backup of"
if [ -z "$WIFI_CON" ]; then
  # Prefer the ACTIVE wifi profile; else the most recently used saved
  # one (nmcli's listing order is not "the one you meant" - a stale
  # hotspot profile must not become the failover target).
  WIFI_CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$WIFI_DEV" '$2==d {print $1; exit}')
  if [ -z "$WIFI_CON" ]; then
    WIFI_CON=$(nmcli -t -f NAME,TYPE,TIMESTAMP con show | awk -F: '$2=="802-11-wireless" {print $3 ":" $1}' | sort -rn | head -1 | cut -d: -f2-)
  fi
fi
[ -n "$WIFI_CON" ] || die "no saved wifi profile - connect to the SSID once first"

# The detected names are interpolated into a generated /bin/sh script;
# refuse metacharacters rather than escaping cleverly.
case "$WIRED_DEV$WIFI_CON$WIRED_CON" in
  *[\"\'\$\`\\]*) die "connection/device names contain shell metacharacters - rename the profile or pass overrides" ;;
esac

ADDR_COUNT=$(nmcli -g IP4.ADDRESS dev show "$WIRED_DEV" | grep -c . || true)
[ "$ADDR_COUNT" = 1 ] || die "$WIRED_DEV has $ADDR_COUNT IPv4 addresses; this script freezes exactly one - resolve manually"
ADDR=$(nmcli -g IP4.ADDRESS dev show "$WIRED_DEV" | head -1)
GW=$(nmcli -g IP4.GATEWAY dev show "$WIRED_DEV" | head -1)
# nmcli -g joins multiple values on one line with " | "; ipv4.dns wants
# commas. (Caught by the pop-os --detect-only preview.)
DNS=$(nmcli -g IP4.DNS dev show "$WIRED_DEV" | sed 's/ | /,/g' | paste -sd, -)
[ -n "$ADDR" ] && [ -n "$GW" ] || die "could not read current IPv4 address/gateway from $WIRED_DEV"

# Refuse if ANY established SSH session terminates on a wifi address:
# the steps below take wifi down. SSH_CONNECTION does not survive sudo's
# env_reset, so ask the socket table instead - and fail CLOSED when wifi
# holds addresses we cannot clear.
PHASE=ssh-guard
WIFI_ADDRS=$( { nmcli -g IP4.ADDRESS dev show "$WIFI_DEV" 2>/dev/null | cut -d/ -f1; nmcli -g IP6.ADDRESS dev show "$WIFI_DEV" 2>/dev/null | cut -d/ -f1; } | grep . || true)
if [ -n "$WIFI_ADDRS" ]; then
  command -v ss >/dev/null || die "wifi holds addresses but ss(8) is missing - cannot prove your session isn't riding wifi; detach wifi manually first"
  for a in $WIFI_ADDRS; do
    if ss -Htn state established '( sport = :22 )' | grep -qF "$a"; then
      die "an established SSH session terminates on wifi address $a - reconnect via ${ADDR%/*} first"
    fi
  done
fi

say "wired : $WIRED_CON on $WIRED_DEV -> static $ADDR gw $GW dns ${DNS:-'(none)'} (autoconnect on)"
say "wifi  : $WIFI_CON on $WIFI_DEV -> same IP, autoconnect off, DOWN (backup)"
if [ "$DETECT_ONLY" = yes ]; then
  trap - EXIT
  say "(detect-only: nothing changed)"
  exit 0
fi
[ "$YES" = yes ] || die "re-run with --yes to apply exactly the above (or --detect-only to preview)"

# --- apply ----------------------------------------------------------------
# Wired goes static with its CURRENT values: the lease it holds today is
# the address everything (k3s, MetalLB pools, export rules, ssh configs)
# already knows. autoconnect is asserted - a wired profile that doesn't
# autoconnect strands the node on every reboot.
PHASE=wired-static
nmcli con mod "$WIRED_CON" ipv4.method manual ipv4.addresses "$ADDR" ipv4.gateway "$GW" ${DNS:+ipv4.dns "$DNS"} ipv4.route-metric 100 connection.autoconnect yes
nmcli dev reapply "$WIRED_DEV" >/dev/null 2>&1 || say "note: live reapply refused (normal for dhcp->manual); the static config is UNTESTED until the next activation - use the dead-man test from the header"

# Wifi claims the SAME address but may never autoconnect; only the
# dispatcher/reconciler below activate it. Higher metric so even a
# misconfigured double-activation prefers wired.
PHASE=wifi-mirror
nmcli con mod "$WIFI_CON" ipv4.method manual ipv4.addresses "$ADDR" ipv4.gateway "$GW" ${DNS:+ipv4.dns "$DNS"} ipv4.route-metric 600 connection.autoconnect no

# The level reconciler: the single place that knows the invariant.
PHASE=reconciler
cat > /usr/local/sbin/wifi-backup-reconcile <<EOF
#!/bin/sh
# Installed by bootstrap/wifi-backup.sh. Enforces: wifi ('$WIFI_CON')
# is up exactly when wired ($WIRED_DEV) is down. Run by the dispatcher
# (fast path, on events) and by wifi-backup.timer (level truth: covers
# cold boot with wired dead, AP bounces while on wifi, missed edges).
WIRED_STATE=\$(/usr/bin/nmcli -g GENERAL.STATE dev show "$WIRED_DEV" 2>/dev/null)
WIFI_ACTIVE=\$(/usr/bin/nmcli -t -f NAME con show --active | /bin/grep -cxF "$WIFI_CON")
case "\$WIRED_STATE" in
  *connected*)
    if [ "\$WIFI_ACTIVE" != 0 ]; then
      /usr/bin/logger -t wifi-backup "wired up; taking down '$WIFI_CON'"
      /usr/bin/nmcli --wait 5 con down "$WIFI_CON" || true
    fi
    ;;
  *)
    if [ "\$WIFI_ACTIVE" = 0 ]; then
      /usr/bin/logger -t wifi-backup "wired not connected; bringing up '$WIFI_CON'"
      /usr/bin/nmcli --wait 20 con up "$WIFI_CON" || /usr/bin/logger -t wifi-backup "wifi backup FAILED to come up"
    fi
    ;;
esac
EOF
chmod 755 /usr/local/sbin/wifi-backup-reconcile

PHASE=dispatcher
cat > /etc/NetworkManager/dispatcher.d/90-wifi-backup <<EOF
#!/bin/sh
# Installed by bootstrap/wifi-backup.sh - fast path only; the logic
# lives in wifi-backup-reconcile (also run by wifi-backup.timer).
[ "\$1" = "$WIRED_DEV" ] || exit 0
case "\$2" in
  up|down) exec /usr/local/sbin/wifi-backup-reconcile ;;
esac
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/90-wifi-backup

PHASE=systemd-timer
cat > /etc/systemd/system/wifi-backup.service <<'EOF'
[Unit]
Description=Reconcile wifi-as-backup against wired link state
After=NetworkManager.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wifi-backup-reconcile
EOF
cat > /etc/systemd/system/wifi-backup.timer <<'EOF'
[Unit]
Description=Level-truth for wifi-as-backup (cold boot, AP bounce, missed edges)
[Timer]
OnBootSec=25
OnUnitActiveSec=120
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now wifi-backup.timer >/dev/null 2>&1

# Backup means down until needed - via the reconciler, so its first
# real execution happens now, watched, not at 3am.
PHASE=first-reconcile
/usr/local/sbin/wifi-backup-reconcile

# --- verify ---------------------------------------------------------------
PHASE=verify
say "--- default routes now:"
ip route show default
NDEF=$(ip route show default | wc -l)
[ "$NDEF" = 1 ] || die "expected exactly one default route, found $NDEF - inspect before trusting failover"
say "--- $WIFI_DEV state:"
nmcli -t -f DEVICE,STATE dev status | grep "^$WIFI_DEV:"
say "--- wifi-backup.timer:"
systemctl is-active wifi-backup.timer
trap - EXIT
say "OK: single-active on $WIRED_DEV at $ADDR; '$WIFI_CON' armed as backup (dispatcher + 2min reconciler)."
say "NOTE: reserve/exclude ${ADDR%/*} on the DHCP server - it is static here now, but the pool doesn't know."
say "Now run the dead-man failover test from the header comment."
