#!/usr/bin/env bash
# assign a persistent ip to the second pcie-domain view of the cabled cx-7 port
# via networkmanager. mirrors the existing profile that manages your other half
# of the same physical port — same mtu, manual ipv4, autoconnect on. (one cable,
# two devices; the box leaves one of them out in the cold like a Sweathog who
# missed the bell. this fixes that.)
#
# default config:
#   iface  = enp1s0f1np1  (override with $IFACE)
#   subnet = 10.10.21.0/24 (override with $SUBNET_PREFIX, e.g. SUBNET_PREFIX=10.10.31)
#   mtu    = 9000          (override with $MTU)
#   profile name = compute-fabric-2 (override with $CON_NAME)
#
# usage (each node):
#   sudo bash setup-second-half.sh <last-octet>
#     node 1: sudo bash setup-second-half.sh 1
#     node 2: sudo bash setup-second-half.sh 2
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "usage: $0 <last-octet>   # e.g. 1 on first node, 2 on second"
  exit 1
fi
OCT=$1
IFACE="${IFACE:-enp1s0f1np1}"
SUBNET_PREFIX="${SUBNET_PREFIX:-10.10.21}"
MTU="${MTU:-9000}"
CON_NAME="${CON_NAME:-compute-fabric-2}"
NEW_IP="${SUBNET_PREFIX}.${OCT}/24"

echo "iface    = $IFACE"
echo "ip       = $NEW_IP"
echo "mtu      = $MTU"
echo "profile  = $CON_NAME"
echo

echo "== before =="
nmcli -t connection show 2>&1 | grep -E "${IFACE}|${CON_NAME}" || true
ip -4 addr show dev "$IFACE" 2>&1 || true
echo

# idempotent: delete prior profile of the same name
if nmcli -t connection show "$CON_NAME" >/dev/null 2>&1; then
  echo "deleting existing $CON_NAME"
  nmcli connection delete "$CON_NAME"
fi

# also delete any other nm profile pinned to this iface, so they don't fight the new one
nmcli -t connection show | awk -F: -v iface="$IFACE" -v keep="$CON_NAME" \
  '$1 != keep && $4 == iface {print $1}' | while read c; do
  echo "deleting prior nm profile for $IFACE: $c"
  nmcli connection delete "$c" || true
done

echo
echo "== creating profile =="
nmcli connection add type ethernet \
  con-name "$CON_NAME" \
  ifname "$IFACE" \
  ipv4.method manual \
  ipv4.addresses "$NEW_IP" \
  ipv6.method ignore \
  802-3-ethernet.mtu "$MTU" \
  connection.autoconnect yes

echo
echo "== bringing up =="
nmcli connection up "$CON_NAME"

echo
echo "== after =="
nmcli -t -f connection.id,connection.interface-name,802-3-ethernet.mtu,ipv4.addresses,ipv4.method,connection.autoconnect connection show "$CON_NAME"
echo
ip -4 addr show dev "$IFACE"
echo "operstate: $(cat /sys/class/net/$IFACE/operstate)  carrier: $(cat /sys/class/net/$IFACE/carrier)  mtu: $(cat /sys/class/net/$IFACE/mtu)"

echo
echo "done. survives reboot. configure the other node too before benching."
