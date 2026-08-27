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
VPN_IF="${VPN_IF:-tun0}"
EDGE_MODE="${EDGE_MODE:-vpn}"
OPENVPN_UNIT="${OPENVPN_UNIT:-openvpn@vpn.service}"
NETLOG_STATE_DIR="${NETLOG_STATE_DIR:-/run/systema-router}"
VPN_IPUP_HOLD="${NETLOG_STATE_DIR}/vpn.restart.hold"
VPN_IPUP_HOLD_SEC="${VPN_IPUP_HOLD_SEC:-30}"

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

vpn_edge_ready() {
  [[ "$EDGE_MODE" == "vpn" ]] || return 0
  ip link show "$VPN_IF" >/dev/null 2>&1 || return 1
  ip -4 addr show "$VPN_IF" 2>/dev/null | grep -q 'inet '
}

vpn_restart_allowed() {
  mkdir -p "$NETLOG_STATE_DIR" 2>/dev/null || true
  local now last=0
  now="$(date +%s)"
  [[ -f "$VPN_IPUP_HOLD" ]] && last="$(cat "$VPN_IPUP_HOLD" 2>/dev/null || echo 0)"
  [[ $((now - last)) -ge $VPN_IPUP_HOLD_SEC ]]
}

maybe_restart_vpn_after_lte() {
  [[ "$EDGE_MODE" == "vpn" ]] || return 0
  vpn_edge_ready && return 0
  vpn_restart_allowed || {
    netlog VPN_RESTART "PPP ip-up: VPN restart отложен (hold)" unit="$OPENVPN_UNIT" reason=ppp_ipup_lte
    return 0
  }
  date +%s >"$VPN_IPUP_HOLD" 2>/dev/null || true
  netlog VPN_RESTART "Перезапуск OpenVPN" unit="$OPENVPN_UNIT" reason=ppp_ipup_lte edge_mode="$EDGE_MODE"
  # Не блокируем pppd на долгом restart
  ( systemctl restart "$OPENVPN_UNIT" >/dev/null 2>&1 || true ) &
}

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
  maybe_restart_vpn_after_lte
else
  ip route replace default dev "$IFACE" metric 500 2>/dev/null || true
  netlog LTE_IPUP "PPP up (WAN уже online, LTE standby)" iface="$IFACE"
fi

exit 0
