#!/usr/bin/env bash
# Point a node's resolver at the homelab zone, without crowding out the
# router.
#
# The homelab zone (*.home.chrisscotmartin.com) is served by pi-hole at
# .230 and, if pi-hole is down, by coredns-secondary at .232. DHCP hands
# every node those two plus the router at .1, in that order, which is
# exactly what is wanted:
#
#   .230  pi-hole          primary, plus ad-blocking
#   .232  coredns-secondary homelab zone failover (no ad-blocking)
#   .1    router            last resort
#
# Only `Domains=` is set here. Setting `DNS=192.168.50.230` as well - which
# pop-os did until 2026-09-17 - adds a SECOND copy of .230 ahead of the
# link's list, and Kubernetes caps a pod's resolv.conf at three
# nameservers. The duplicate took a slot and the router fell off the end:
#
#   nameserver 192.168.50.230    <- global DNS=
#   nameserver 192.168.50.230    <- from DHCP
#   nameserver 192.168.50.232
#   nameserver 192.168.50.1      <- dropped, with a DNSConfigForming warning
#
# That left every host-network pod with three resolvers that are all in
# this cluster, so a cluster-wide outage took DNS with it. The router is
# the only entry that survives that, and it was the one being discarded.
set -euo pipefail

conf=/etc/systemd/resolved.conf.d/homelab.conf

sudo tee "$conf" >/dev/null <<'CONF'
[Resolve]
# Routing-only domain (~): send *.home.chrisscotmartin.com to the link's
# DNS servers rather than treating it as a search suffix. No DNS= here on
# purpose - see the header of bootstrap/host-dns.sh.
Domains=~home.chrisscotmartin.com
CONF

# The old filename, if this node still has it.
sudo rm -f /etc/systemd/resolved.conf.d/pihole.conf

sudo systemctl restart systemd-resolved

echo "resolvers now:"
grep nameserver /run/systemd/resolve/resolv.conf | sed 's/^/  /'
echo
echo "expect three distinct entries ending in 192.168.50.1 - if the router"
echo "is missing, a duplicate has crept back in."
