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
# IP as the wired profile, autoconnect off. A NetworkManager dispatcher
# script brings wifi up when the wired link drops and back down when it
# returns. The node's address never changes, so k3s registration,
# MetalLB, flannel and NFS export rules see nothing; a failover is a
# few seconds of retransmits inside existing TCP connections.
# (The kernel-native alternative - an active-backup bond - was rejected:
# wifi slaves need fail_over_mac juggling and driver cooperation; the
# dispatcher is dumber and that is its virtue.)
#
# Run AS ROOT on each node, over the WIRED connection (it aborts if your
# SSH rides the wifi address - applying this over wifi strands you):
#
#   sudo bash bootstrap/wifi-backup.sh
#
# Afterwards, test failover WITHOUT risking a stranded node: schedule a
# dead-man restore first, then drop the wired link -
#
#   sudo systemd-run --on-active=90 nmcli con up "<wired con>"
#   sudo nmcli dev disconnect <wired dev>
#   # watch: wifi comes up holding the same IP; ssh survives.
#   sudo nmcli con up "<wired con>"   # or let the dead-man do it
#
# A software disconnect exercises the dispatcher's down/up path; a real
# cable pull additionally proves carrier detection - do one of those too
# before trusting it.
set -euo pipefail

say() { printf '%s\n' "$*"; }
die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
command -v nmcli >/dev/null || die "NetworkManager (nmcli) not found - this node needs a different recipe"

# --- detect ---------------------------------------------------------------
WIRED_DEV=$(nmcli -t -f DEVICE,TYPE,STATE dev status | awk -F: '$2=="ethernet" && $3=="connected" {print $1; exit}')
[ -n "${WIRED_DEV:-}" ] || die "no connected ethernet device - bring the wired link up first"
WIRED_CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$WIRED_DEV" '$2==d {print $1; exit}')
[ -n "${WIRED_CON:-}" ] || die "no active connection on $WIRED_DEV"

WIFI_DEV=$(nmcli -t -f DEVICE,TYPE dev status | awk -F: '$2=="wifi" {print $1; exit}')
[ -n "${WIFI_DEV:-}" ] || die "no wifi device - nothing to make a backup of"
# The wifi CONNECTION: prefer the active one, else the first wireless
# profile (the saved SSID+credentials survive our ipv4 changes).
WIFI_CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$WIFI_DEV" '$2==d {print $1; exit}')
if [ -z "${WIFI_CON:-}" ]; then
  WIFI_CON=$(nmcli -t -f NAME,TYPE con show | awk -F: '$2=="802-11-wireless" {print $1; exit}')
fi
[ -n "${WIFI_CON:-}" ] || die "no saved wifi profile - connect to the SSID once first"

ADDR=$(nmcli -g IP4.ADDRESS dev show "$WIRED_DEV" | head -1)
GW=$(nmcli -g IP4.GATEWAY dev show "$WIRED_DEV" | head -1)
# nmcli -g joins multiple values on one line with " | "; ipv4.dns wants
# commas. (Caught by the pop-os --detect-only preview.)
DNS=$(nmcli -g IP4.DNS dev show "$WIRED_DEV" | sed 's/ | /,/g' | paste -sd, -)
[ -n "$ADDR" ] && [ -n "$GW" ] || die "could not read current IPv4 address/gateway from $WIRED_DEV"

# Refuse to proceed if this session arrived via the wifi address: the
# steps below take wifi down.
WIFI_ADDR=$(nmcli -g IP4.ADDRESS dev show "$WIFI_DEV" 2>/dev/null | head -1 | cut -d/ -f1)
if [ -n "${SSH_CONNECTION:-}" ] && [ -n "$WIFI_ADDR" ]; then
  case "$SSH_CONNECTION" in
    *" $WIFI_ADDR "*) die "your SSH session rides the wifi address $WIFI_ADDR - reconnect via ${ADDR%/*} first" ;;
  esac
fi

say "wired : $WIRED_CON on $WIRED_DEV -> static $ADDR gw $GW dns ${DNS:-'(none)'}"
say "wifi  : $WIFI_CON on $WIFI_DEV -> same IP, autoconnect off, DOWN (backup)"

# --- apply ----------------------------------------------------------------
# Wired goes static with its CURRENT values: the lease it holds today is
# the address everything (k3s, MetalLB pools, export rules, ssh configs)
# already knows. reapply avoids bouncing the link for an identical IP.
nmcli con mod "$WIRED_CON" ipv4.method manual ipv4.addresses "$ADDR" ipv4.gateway "$GW" ${DNS:+ipv4.dns "$DNS"} ipv4.route-metric 100
nmcli dev reapply "$WIRED_DEV" >/dev/null || say "note: reapply refused; the static config lands on next activation"

# Wifi claims the SAME address but may never autoconnect; only the
# dispatcher below activates it. Higher metric so even a misconfigured
# double-activation prefers wired.
nmcli con mod "$WIFI_CON" ipv4.method manual ipv4.addresses "$ADDR" ipv4.gateway "$GW" ${DNS:+ipv4.dns "$DNS"} ipv4.route-metric 600 connection.autoconnect no

DISPATCH=/etc/NetworkManager/dispatcher.d/90-wifi-backup
cat > "$DISPATCH" <<EOF
#!/bin/sh
# Installed by bootstrap/wifi-backup.sh - wifi is the wired link's
# backup, holding the same address. Only this script activates it.
WIRED_DEV="$WIRED_DEV"
WIFI_CON="$WIFI_CON"
[ "\$1" = "\$WIRED_DEV" ] || exit 0
case "\$2" in
  down)
    logger -t wifi-backup "wired \$1 down; bringing up '\$WIFI_CON'"
    nmcli con up "\$WIFI_CON" || logger -t wifi-backup "wifi backup FAILED to come up"
    ;;
  up)
    logger -t wifi-backup "wired \$1 up; taking down '\$WIFI_CON'"
    nmcli con down "\$WIFI_CON" 2>/dev/null || true
    ;;
esac
EOF
chmod 755 "$DISPATCH"

# Backup means down until needed.
nmcli con down "$WIFI_CON" 2>/dev/null || true

# --- verify ---------------------------------------------------------------
say "--- default routes now:"
ip route show default
NDEF=$(ip route show default | wc -l)
[ "$NDEF" = 1 ] || die "expected exactly one default route, found $NDEF - inspect before trusting failover"
say "--- $WIFI_DEV state:"
nmcli -t -f DEVICE,STATE dev status | grep "^$WIFI_DEV:"
say "OK: single-active on $WIRED_DEV at $ADDR; '$WIFI_CON' armed as backup."
say "Now run the dead-man failover test from the header comment."
