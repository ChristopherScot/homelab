#!/bin/bash

# Make iSCSI survive Wi-Fi dropouts instead of losing the session.
#
# These nodes reach the Synology (192.168.50.220) over Wi-Fi, which cannot be
# changed. The stock open-iscsi timeouts assume a wired datacenter link and are
# far too aggressive for a wireless one.
#
# What the defaults did to us on 2026-10-29:
#
#   01:58:00  wlo1: deauthenticated from <AP> (Reason: 3=DEAUTH_LEAVING)
#   01:58:07  connection15:0: ping timeout of 5 secs expired
#   01:58:07  connection15:0: detected conn error (1022)
#   02:00:08  session15: session recovery timed out after 120 secs
#   02:00:08  sd 12:0:0:1: rejecting I/O to offline device
#   02:00:08  BTRFS error (device sdm state A): Transaction aborted (error -5)
#   02:00:08  BTRFS info (device sdm state EA): forced readonly
#
# A ~2 minute Wi-Fi outage exceeded replacement_timeout, so iscsid gave up,
# the kernel marked the devices offline, and every filesystem on them aborted
# its journal. qBittorrent's /config (btrfs on sdm) was still read-only three
# days later; ext4 volumes under Postgres, Loki, VictoriaMetrics, Radarr and
# litestream aborted their journals in the same window. The SCSI "Medium Error
# / Unrecovered read error" lines are the target failing I/O while the link was
# down - the Synology's own drives and pool report Healthy with ~9TB free.
#
# The fix is to wait the outage out rather than tear the session down:
#
#   replacement_timeout  120 -> 900  queue I/O for 15 min instead of erroring.
#                                    Callers block and then continue once Wi-Fi
#                                    returns; filesystems stay mounted.
#   noop_out_interval      5 -> 15   stop probing so often.
#   noop_out_timeout       5 -> 30   brief jitter is no longer a conn error.
#
# TRADE-OFF: if the NAS is genuinely dead (not a blip), pods now hang on I/O
# for up to 15 minutes instead of failing in 2. That is deliberate. A hang is
# recoverable; a read-only root filesystem on a running database is not.
#
# Idempotent: safe to re-run. Both the on-disk config (applies at next login)
# and the live sessions in sysfs (applies now) are updated.

set -euo pipefail

ISCSID_CONF=/etc/iscsi/iscsid.conf

REPLACEMENT_TIMEOUT=900
NOOP_INTERVAL=15
NOOP_TIMEOUT=30

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (needs to write $ISCSID_CONF and sysfs)." >&2
    exit 1
fi

if [ ! -f "$ISCSID_CONF" ]; then
    echo "ERROR: $ISCSID_CONF not found - is open-iscsi installed?" >&2
    exit 1
fi

# Replace the setting in place if present (commented or not), else append it.
# open-iscsi reads the LAST matching line, but rewriting in place keeps the
# file readable and avoids a pile-up of appended overrides on re-runs.
set_iscsi_option() {
    local key="$1" value="$2" file="$3"
    local escaped_key
    escaped_key=$(printf '%s' "$key" | sed 's/[][\.*^$/]/\\&/g')

    if grep -qE "^[[:space:]]*#?[[:space:]]*${escaped_key}[[:space:]]*=" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${escaped_key}[[:space:]]*=.*|${key} = ${value}|" "$file"
    else
        printf '%s = %s\n' "$key" "$value" >> "$file"
    fi
}

BACKUP="${ISCSID_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
cp -a "$ISCSID_CONF" "$BACKUP"
echo "Backed up $ISCSID_CONF -> $BACKUP"

set_iscsi_option "node.session.timeo.replacement_timeout" "$REPLACEMENT_TIMEOUT" "$ISCSID_CONF"
set_iscsi_option "node.conn[0].timeo.noop_out_interval"   "$NOOP_INTERVAL"       "$ISCSID_CONF"
set_iscsi_option "node.conn[0].timeo.noop_out_timeout"    "$NOOP_TIMEOUT"        "$ISCSID_CONF"

echo "Updated $ISCSID_CONF:"
grep -E "replacement_timeout|noop_out_interval|noop_out_timeout" "$ISCSID_CONF" \
    | grep -vE "^[[:space:]]*#" | sed 's/^/  /'

# iscsid.conf is only consulted at login, so already-connected sessions keep
# the old recovery_tmo until they reconnect. Push the new value to the live
# sessions too - this takes effect immediately and is not disruptive.
updated=0
for tmo in /sys/class/iscsi_session/session*/recovery_tmo; do
    [ -e "$tmo" ] || continue
    if printf '%s\n' "$REPLACEMENT_TIMEOUT" > "$tmo" 2>/dev/null; then
        updated=$((updated + 1))
    else
        echo "WARNING: could not write $tmo" >&2
    fi
done

if [ "$updated" -gt 0 ]; then
    echo "Set recovery_tmo=${REPLACEMENT_TIMEOUT} on ${updated} live session(s)."
else
    echo "No live iSCSI sessions found (nothing to update in sysfs)."
fi

# Per-node records under /etc/iscsi/nodes/ carry their own copy of the timeout,
# captured at discovery. Without this, a re-login would restore 120.
if [ -d /etc/iscsi/nodes ]; then
    node_files=$(grep -rlE "node\.session\.timeo\.replacement_timeout" /etc/iscsi/nodes 2>/dev/null || true)
    if [ -n "$node_files" ]; then
        printf '%s\n' "$node_files" | while IFS= read -r nf; do
            sed -i -E "s|^[[:space:]]*node\.session\.timeo\.replacement_timeout[[:space:]]*=.*|node.session.timeo.replacement_timeout = ${REPLACEMENT_TIMEOUT}|" "$nf"
        done
        echo "Updated replacement_timeout in $(printf '%s\n' "$node_files" | wc -l) node record(s)."
    fi
fi

echo
echo "Done. New logins use $ISCSID_CONF; live sessions were updated in place."
echo "No restart of iscsid is required, and none is performed here - restarting"
echo "it while volumes are mounted is riskier than the change itself."
