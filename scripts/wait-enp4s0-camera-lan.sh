#!/usr/bin/env bash
# Ждём LAN-адрес; форсируем адрес даже без carrier (ignore-carrier)
set -euo pipefail
# shellcheck disable=SC1091
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh"
type netlog >/dev/null 2>&1 || netlog() { :; }

# shellcheck disable=SC1091

LAN_IF="${LAN_IF:-enp4s0}"
LAN_CIDR="${LAN_CIDR:-192.168.50.1/24}"
LAN_ADDR="${LAN_ADDR:-192.168.50.1}"

ready() {
  ip -4 addr show dev "$LAN_IF" 2>/dev/null | grep -q "inet ${LAN_ADDR}/"
}

ensure_lan() {
  ip link set "$LAN_IF" up 2>/dev/null || true
  networkctl up "$LAN_IF" 2>/dev/null || true
  if ! ready; then
    ip addr add "$LAN_CIDR" dev "$LAN_IF" 2>/dev/null || true
  fi
}

ensure_lan
for i in $(seq 1 30); do
  if ready; then
    [[ "$i" -gt 1 ]] && netlog LAN_READY "LAN адрес готов" iface="$LAN_IF" addr="$LAN_CIDR" waited_s="$i"
    exit 0
  fi
  ensure_lan
  echo "waiting for ${LAN_IF} ${LAN_CIDR}... (${i}/30)"
  sleep 1
done

netlog LAN_NOT_READY "LAN не поднялся до старта dnsmasq" iface="$LAN_IF" addr="$LAN_CIDR"
echo "ERROR: ${LAN_IF} ${LAN_CIDR} not ready" >&2
exit 1
