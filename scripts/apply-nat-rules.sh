#!/usr/bin/env bash
# Применение iptables: NAT + опциональный проброс с edge (VPN или white IP) → LAN
set -euo pipefail
# shellcheck disable=SC1091
: "${SYSTEMA_ROUTER_ROOT:=${PC_ROUTER_ROOT:-/home/admin/PC-Router}}"
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh"
type netlog >/dev/null 2>&1 || netlog() { :; }


WAN_IF="${WAN_IF:-enp3s0}"
LAN_IF="${LAN_IF:-enp4s0}"
LTE_IF="${LTE_IF:-ppp0}"
VPN_IF="${VPN_IF:-tun0}"
EDGE_MODE="${EDGE_MODE:-vpn}"
WHITE_IF="${WHITE_IF:-$WAN_IF}"
LAN_NET="${LAN_NET:-192.168.50.0/24}"

case "$EDGE_MODE" in
  vpn) EDGE_IF="$VPN_IF" ;;
  whiteip) EDGE_IF="${WHITE_IF:-$WAN_IF}" ;;
  none) EDGE_IF="" ;;
  *) EDGE_IF="$VPN_IF" ;;
esac

add_nat() {
  local out_if="$1"
  iptables -t nat -C POSTROUTING -o "$out_if" -s "$LAN_NET" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$out_if" -s "$LAN_NET" -j MASQUERADE
}

add_fwd() {
  iptables -C FORWARD "$@" 2>/dev/null || iptables -A FORWARD "$@"
}

add_dnat() {
  local vport="$1" dip="$2" dport="$3"
  [[ -z "$EDGE_IF" ]] && return 0
  iptables -t nat -C PREROUTING -i "$EDGE_IF" -p tcp --dport "$vport" -j DNAT --to-destination "${dip}:${dport}" 2>/dev/null \
    || iptables -t nat -A PREROUTING -i "$EDGE_IF" -p tcp --dport "$vport" -j DNAT --to-destination "${dip}:${dport}"
  add_fwd -i "$EDGE_IF" -o "$LAN_IF" -p tcp -d "$dip" --dport "$dport" -j ACCEPT
}

add_fwd -i "$WAN_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
add_fwd -i "$LTE_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
add_fwd -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT
add_fwd -i "$LAN_IF" -o "$LTE_IF" -j ACCEPT
if [[ -n "$EDGE_IF" ]]; then
  add_fwd -i "$LAN_IF" -o "$EDGE_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

add_nat "$WAN_IF"
add_nat "$LTE_IF"

iptables -t nat -C POSTROUTING -o "$LAN_IF" -d "$LAN_NET" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$LAN_IF" -d "$LAN_NET" -j MASQUERADE

IFS=';' read -ra FORWARDS <<<"${DEVICE_FORWARDS:-}"
for item in "${FORWARDS[@]}"; do
  [[ -z "$item" ]] && continue
  IFS=':' read -r vport dip dport <<<"$item"
  add_dnat "$vport" "$dip" "$dport"
done

echo "iptables rules applied (EDGE_MODE=$EDGE_MODE EDGE_IF=${EDGE_IF:-none} config=$CONFIG_FILE)"
