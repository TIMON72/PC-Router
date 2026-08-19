#!/bin/bash
# networkd-dispatcher: при появлении carrier/routable на LAN — убедиться что dnsmasq жив
set -u
# shellcheck disable=SC1091
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh"
type netlog >/dev/null 2>&1 || netlog() { :; }
IFACE="${IFACE:-}"
[[ "$IFACE" == "enp4s0" ]] || exit 0

# shellcheck disable=SC1091

LAN_ADDR="${LAN_ADDR:-192.168.50.1}"
LAN_CIDR="${LAN_CIDR:-192.168.50.1/24}"

ip link set enp4s0 up 2>/dev/null || true
if ! ip -4 addr show enp4s0 2>/dev/null | grep -q "inet ${LAN_ADDR}/"; then
  ip addr add "$LAN_CIDR" dev enp4s0 2>/dev/null || true
fi

if ! systemctl is-active --quiet dnsmasq; then
  systemctl start dnsmasq 2>/dev/null || true
  netlog DHCP_RESTART "dnsmasq стартовал после LAN carrier" iface=enp4s0
else
  # мягкий SIGHUP чтобы подхватить interface после flap
  systemctl kill -s HUP dnsmasq 2>/dev/null || true
fi
netlog LAN_CARRIER "LAN carrier/routable" iface=enp4s0 state="${STATE:-unknown}"
exit 0
