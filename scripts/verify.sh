#!/usr/bin/env bash
# Быстрая проверка после install / на уже настроенной площадке
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
OPENVPN_UNIT="${OPENVPN_UNIT:-openvpn@vpn.service}"

echo "=== interfaces ==="
ip -br a
echo
echo "=== routes ==="
ip route
echo
echo "=== EDGE_MODE=$EDGE_MODE ==="
echo
echo "=== services ==="
case "$EDGE_MODE" in
  vpn)
    systemctl is-active dnsmasq lte lte-failover "$OPENVPN_UNIT" 2>/dev/null || true
    vpn_en="$(systemctl is-enabled "$OPENVPN_UNIT" 2>/dev/null || echo unknown)"
    base_en="$(systemctl is-enabled openvpn.service 2>/dev/null || echo unknown)"
    echo "openvpn instance: $vpn_en  openvpn.service: $base_en"
    if [[ "$vpn_en" != "enabled" ]]; then
      profile="${OPENVPN_UNIT#*@}"
      profile="${profile%.service}"
      autostart="$(grep -E '^AUTOSTART=' /etc/default/openvpn 2>/dev/null | sed -n 's/^AUTOSTART=//p' | tr -d '\"' || true)"
      if [[ "$vpn_en" == "enabled-runtime" && "$base_en" == "enabled" \
        && { [[ "$autostart" == "all" ]] || [[ "$autostart" == "$profile" ]] || [[ " $autostart " == *" $profile "* ]]; } ]]; then
        echo "OK: autostart через openvpn.service (AUTOSTART=$autostart)"
      else
        echo "WARN: нет постоянного autostart — sudo systemctl enable $OPENVPN_UNIT"
      fi
    fi
    ;;
  *)
    systemctl is-active dnsmasq lte lte-failover 2>/dev/null || true
    ;;
esac
echo
echo "=== ip_forward ==="
cat /proc/sys/net/ipv4/ip_forward
echo
echo "=== dnsmasq leases ==="
cat /var/lib/misc/dnsmasq.leases 2>/dev/null || true
echo
echo "=== static device leases (from config) ==="
if [[ -n "${DEVICE_LEASES:-}" ]]; then
  IFS=';' read -ra LEASES <<<"$DEVICE_LEASES"
  for item in "${LEASES[@]}"; do
    [[ -z "$item" ]] && continue
    IFS=',' read -r _mac ip _name <<<"$item"
    [[ -z "${ip:-}" ]] && continue
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
      echo "$ip OK"
    else
      echo "$ip FAIL"
    fi
  done
else
  echo "(DEVICE_LEASES пусто — пропуск)"
fi
echo
echo "=== uplink pings ==="
if ip link show "$WAN_IF" >/dev/null 2>&1; then
  ping -I "$WAN_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "WAN ping OK" || echo "WAN ping FAIL"
fi
if ip link show "$LTE_IF" >/dev/null 2>&1; then
  ping -I "$LTE_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "LTE ping OK" || echo "LTE ping FAIL/zombie?"
else
  echo "LTE iface missing"
fi
echo
echo "=== edge ==="
case "$EDGE_MODE" in
  vpn)
    ip -br a show "$VPN_IF" 2>/dev/null || echo "no $VPN_IF"
    if [[ -n "${VPN_PING_HOST:-}" ]]; then
      ping -c 1 -W 2 "$VPN_PING_HOST" >/dev/null 2>&1 && echo "VPN_PING_HOST OK" || echo "VPN_PING_HOST FAIL"
    fi
    ;;
  whiteip)
    ip -br a show "$WHITE_IF" 2>/dev/null || echo "no $WHITE_IF"
    if [[ -n "${WHITE_IP:-}" ]]; then
      if ip -4 -o addr show dev "$WHITE_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$WHITE_IP"; then
        echo "WHITE_IP $WHITE_IP OK"
      else
        echo "WHITE_IP $WHITE_IP FAIL"
      fi
    fi
    if [[ -n "${WHITE_PING_HOST:-}" ]]; then
      ping -c 1 -W 2 "$WHITE_PING_HOST" >/dev/null 2>&1 && echo "WHITE_PING_HOST OK" || echo "WHITE_PING_HOST FAIL"
    fi
    ;;
  none)
    echo "(EDGE_MODE=none — без edge-проверки)"
    ;;
esac
echo
echo "=== failover log (tail) ==="
tail -n 15 "${LOG_FILE:-$SYSTEMA_ROUTER_ROOT/lte-failover.log}" 2>/dev/null || true
