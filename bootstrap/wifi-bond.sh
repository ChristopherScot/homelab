#!/usr/bin/env bash
# Ethernet-primary / wifi-backup via a kernel active-backup BOND: one
# logical interface (bond0) holds the node's one address forever; the
# kernel fails over between the wired port and the wifi in milliseconds
# on carrier loss, and fails back to wired when it returns. The wifi
# stays associated the whole time - a warm standby, never a second IP.
#
# This is the native replacement for bootstrap/wifi-backup.sh (the
# dispatcher+reconciler approach): same goal, one declarative construct
# instead of generated scripts. wifi-backup.sh REMAINS the fallback for
# a node whose wifi driver refuses bond enslavement - that refusal is
# exactly what the pop-os test of this script determines. Context for
# why single-active-one-IP at all: wifi-backup.sh's header (2026-11-10).
#
# Bond specifics that matter:
#   - mode=active-backup, primary=<wired>: wired wins whenever it has
#     carrier; wifi only carries traffic while wired is down.
#   - fail_over_mac=active: the bond adopts the ACTIVE slave's MAC.
#     Required for wifi - an AP drops frames from a source MAC that
#     never associated, so the bond must wear the wifi's own MAC while
#     failed over. Failback re-adopts the wired MAC (gratuitous ARP
#     re-points the switch).
#   - miimon=100: carrier checked every 100ms.
#
# THE TRANSITION IS THE RISKY MOMENT: enslaving the wired port tears
# down the connection your SSH rides. The switchover therefore runs as
# a detached systemd unit on the node (survives your session dropping)
# with a dead-man revert - if bond0 isn't healthy after 90s, the old
# wired profile comes back automatically. The old profiles are kept
# (autoconnect off) as the manual rollback:
#   nmcli con down bond0; nmcli con up "<old wired con>"
#
# Run AS ROOT on the node, over the wired connection:
#   sudo bash bootstrap/wifi-bond.sh --detect-only   # preview
#   sudo bash bootstrap/wifi-bond.sh --yes           # apply
# Overrides: --wired-dev DEV --wifi-con NAME.
#
# After it reports healthy: test for real. Pull the cable - the bond
# fails to wifi in under a second (watch: cat /proc/net/bonding/bond0).
# Plug back - it fails back to wired. Your SSH should survive both.
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
command -v nmcli >/dev/null || die "NetworkManager (nmcli) not found"

PHASE=detect
trap 'rc=$?; [ $rc -ne 0 ] && printf "FAILED during phase: %s\nThe old profiles are untouched until the transition phase; before that, nothing changed.\nAfter it: the dead-man restores the old wired profile within 90s, or run: nmcli con up \"$WIRED_CON\"\n" "$PHASE" >&2' EXIT

# --- detect (same discipline as wifi-backup.sh) ---------------------------
if [ -z "$WIRED_DEV" ]; then
  ETH_COUNT=$(nmcli -t -f DEVICE,TYPE,STATE dev status | awk -F: '$2=="ethernet" && $3=="connected"' | wc -l)
  [ "$ETH_COUNT" -le 1 ] || die "multiple connected ethernet devices - pass --wired-dev"
  WIRED_DEV=$(nmcli -t -f DEVICE,TYPE,STATE dev status | awk -F: '$2=="ethernet" && $3=="connected" {print $1; exit}')
fi
[ -n "$WIRED_DEV" ] || die "no connected ethernet device"
WIRED_CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$WIRED_DEV" '$2==d {print $1; exit}')
[ -n "${WIRED_CON:-}" ] || die "no active connection on $WIRED_DEV"

WIFI_DEV=$(nmcli -t -f DEVICE,TYPE dev status | awk -F: '$2=="wifi" {print $1; exit}')
[ -n "${WIFI_DEV:-}" ] || die "no wifi device"
if [ -z "$WIFI_CON" ]; then
  WIFI_CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$WIFI_DEV" '$2==d {print $1; exit}')
  [ -n "$WIFI_CON" ] || WIFI_CON=$(nmcli -t -f NAME,TYPE,TIMESTAMP con show | awk -F: '$2=="802-11-wireless" {print $3 ":" $1}' | sort -rn | head -1 | cut -d: -f2-)
fi
[ -n "$WIFI_CON" ] || die "no saved wifi profile - connect to the SSID once first"

case "$WIRED_DEV$WIFI_DEV$WIFI_CON$WIRED_CON" in
  *[\"\'\$\`\\]*) die "names contain shell metacharacters - rename or override" ;;
esac

SSID=$(nmcli -g 802-11-wireless.ssid con show "$WIFI_CON")
PSK=$(nmcli -s -g 802-11-wireless-security.psk con show "$WIFI_CON" || true)
[ -n "$SSID" ] || die "could not read SSID from '$WIFI_CON'"
[ -n "$PSK" ] || die "could not read PSK from '$WIFI_CON' (open networks unsupported here on purpose)"

ADDR_COUNT=$(nmcli -g IP4.ADDRESS dev show "$WIRED_DEV" | grep -c . || true)
[ "$ADDR_COUNT" = 1 ] || die "$WIRED_DEV has $ADDR_COUNT IPv4 addresses; expected exactly one"
ADDR=$(nmcli -g IP4.ADDRESS dev show "$WIRED_DEV" | head -1)
GW=$(nmcli -g IP4.GATEWAY dev show "$WIRED_DEV" | head -1)
# nmcli -g joins multiple values with " | "; ipv4.dns wants commas.
DNS=$(nmcli -g IP4.DNS dev show "$WIRED_DEV" | sed 's/ | /,/g' | paste -sd, -)
[ -n "$ADDR" ] && [ -n "$GW" ] || die "could not read IPv4 address/gateway from $WIRED_DEV"

# SSH-over-wifi guard (socket table; SSH_CONNECTION dies under sudo).
PHASE=ssh-guard
WIFI_ADDRS=$( { nmcli -g IP4.ADDRESS dev show "$WIFI_DEV" 2>/dev/null | cut -d/ -f1; nmcli -g IP6.ADDRESS dev show "$WIFI_DEV" 2>/dev/null | cut -d/ -f1; } | grep . || true)
if [ -n "$WIFI_ADDRS" ]; then
  command -v ss >/dev/null || die "wifi holds addresses but ss(8) missing - cannot prove session safety"
  for a in $WIFI_ADDRS; do
    ss -Htn state established '( sport = :22 )' | grep -qF "$a" && die "an SSH session terminates on wifi address $a - reconnect via ${ADDR%/*}"
  done
fi

say "bond0      : $ADDR gw $GW dns ${DNS:-'(none)'} mode=active-backup primary=$WIRED_DEV fail_over_mac=active"
say "wired port : $WIRED_DEV (from '$WIRED_CON', kept as rollback, autoconnect off)"
say "wifi port  : $WIFI_DEV ssid '$SSID' (from '$WIFI_CON', kept as rollback, autoconnect off)"
if [ "$DETECT_ONLY" = yes ]; then trap - EXIT; say "(detect-only: nothing changed)"; exit 0; fi
[ "$YES" = yes ] || die "re-run with --yes to apply exactly the above"

# --- create the bond profiles (inert until the transition) ----------------
PHASE=create-profiles
for c in bond0 bond0-port-eth bond0-port-wifi; do nmcli con delete "$c" >/dev/null 2>&1 || true; done
nmcli con add type bond ifname bond0 con-name bond0 \
  bond.options "mode=active-backup,primary=$WIRED_DEV,miimon=100,fail_over_mac=active" \
  ipv4.method manual ipv4.addresses "$ADDR" ipv4.gateway "$GW" ${DNS:+ipv4.dns "$DNS"} \
  ipv6.method disabled connection.autoconnect yes connection.autoconnect-slaves 1 >/dev/null
nmcli con add type ethernet ifname "$WIRED_DEV" con-name bond0-port-eth \
  master bond0 connection.autoconnect yes >/dev/null
nmcli con add type wifi ifname "$WIFI_DEV" con-name bond0-port-wifi \
  master bond0 ssid "$SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" \
  connection.autoconnect yes >/dev/null

# --- transition: detached + dead-man --------------------------------------
# Tearing down the old wired profile drops the SSH session running this
# script, so the switch runs as a transient systemd unit (survives us)
# and a second unit reverts everything unless the bond proves healthy.
PHASE=transition
cat > /run/wifi-bond-switch.sh <<EOF
#!/bin/bash
set -x
nmcli con mod "$WIRED_CON" connection.autoconnect no
nmcli con mod "$WIFI_CON" connection.autoconnect no
nmcli con down "$WIFI_CON" 2>/dev/null || true
nmcli con down "$WIRED_CON" 2>/dev/null || true
nmcli --wait 30 con up bond0
sleep 3
if ip -4 addr show bond0 | grep -qF "${ADDR%/*}" && ping -c2 -W2 "$GW" >/dev/null; then
  touch /run/wifi-bond-healthy
  logger -t wifi-bond "bond0 healthy at $ADDR"
else
  logger -t wifi-bond "bond0 UNHEALTHY - reverting now"
  /run/wifi-bond-revert.sh
fi
EOF
cat > /run/wifi-bond-revert.sh <<EOF
#!/bin/bash
[ -e /run/wifi-bond-healthy ] && exit 0
logger -t wifi-bond "dead-man: restoring '$WIRED_CON'"
nmcli con down bond0 2>/dev/null || true
nmcli con mod bond0 connection.autoconnect no 2>/dev/null || true
nmcli con mod "$WIRED_CON" connection.autoconnect yes
nmcli --wait 30 con up "$WIRED_CON"
EOF
chmod 755 /run/wifi-bond-switch.sh /run/wifi-bond-revert.sh
rm -f /run/wifi-bond-healthy
systemd-run --unit wifi-bond-deadman --on-active=90 /run/wifi-bond-revert.sh >/dev/null 2>&1
systemd-run --unit wifi-bond-switch /run/wifi-bond-switch.sh >/dev/null 2>&1

say "transition launched (detached). Reconnect if your SSH drops - the"
say "address stays ${ADDR%/*} either way (bond0, or reverted wired)."
PHASE=watch
for i in $(seq 1 24); do
  sleep 5
  if [ -e /run/wifi-bond-healthy ]; then
    trap - EXIT
    say "--- bond0:"
    grep -E "Bonding Mode|Currently Active Slave|MII Status" /proc/net/bonding/bond0 | head -6
    ip route show default
    say "OK: bond0 active at $ADDR, wired primary, wifi warm standby."
    say "Old profiles kept for rollback: nmcli con down bond0; nmcli con up \"$WIRED_CON\""
    say "NOTE: reserve/exclude ${ADDR%/*} on the DHCP server."
    say "Now pull the cable: active slave should flip to $WIFI_DEV in <1s."
    exit 0
  fi
done
say "transition still unconfirmed after 120s - if connectivity is gone,"
say "the dead-man restores '$WIRED_CON' on its own. Check: journalctl -t wifi-bond"
exit 1
