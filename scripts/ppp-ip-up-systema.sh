#!/bin/bash
# Вызывается pppd при подъёме интерфейса (ip-up.d)
# Сразу даём LAN-клиентам маршрут через LTE, не дожидаясь цикла failover
set -u
# shellcheck disable=SC1091
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh"
type netlog >/dev/null 2>&1 || netlog() { :; }

IFACE="${1:-${PPP_IFACE:-}}"
[[ "$IFACE" == "ppp0" || -n "${PPP_IFACE:-}" ]] || exit 0
IFACE="${IFACE:-ppp0}"

# shellcheck disable=SC1091

WAN_IF="${WAN_IF:-enp3s0}"
LAN_NET="${LAN_NET:-192.168.50.0/24}"

# NAT для LAN → LTE
iptables -t nat -C POSTROUTING -o "$IFACE" -s "$LAN_NET" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$IFACE" -s "$LAN_NET" -j MASQUERADE
iptables -C FORWARD -i enp4s0 -o "$IFACE" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i enp4s0 -o "$IFACE" -j ACCEPT
iptables -C FORWARD -i "$IFACE" -o enp4s0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$IFACE" -o enp4s0 -m state --state RELATED,ESTABLISHED -j ACCEPT

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# Если WAN ещё не online — сразу default через LTE
wan_ok=0
if [[ "$(cat /sys/class/net/${WAN_IF}/operstate 2>/dev/null || echo down)" == "up" ]] \
  && ip -4 addr show "$WAN_IF" 2>/dev/null | grep -q 'inet ' \
  && ping -I "$WAN_IF" -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
  wan_ok=1
fi

if [[ $wan_ok -eq 0 ]]; then
  # убрать stale default через мёртвый WAN
  while read -r line; do
    [[ -z "$line" ]] && continue
    # shellcheck disable=SC2086
    ip route del $line 2>/dev/null || true
  done < <(ip route show default 2>/dev/null | grep " dev ${WAN_IF} " || true)
  ip route replace default dev "$IFACE" metric 100 2>/dev/null || true
  ip route replace default dev "$IFACE" metric 500 2>/dev/null || true
  echo "lte" >/run/lte-failover.state.pathhint 2>/dev/null || true
  netlog LTE_IPUP "PPP up → default через LTE (WAN offline)" iface="$IFACE"
else
  ip route replace default dev "$IFACE" metric 500 2>/dev/null || true
  netlog LTE_IPUP "PPP up (WAN уже online, LTE standby)" iface="$IFACE"
fi

exit 0
