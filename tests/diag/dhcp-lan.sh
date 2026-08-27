#!/usr/bin/env bash
# DHCP/LAN health: dnsmasq жив, LAN-адрес на месте, число клиентов.
# Работает по SSH с любой стороны — не требует ПК в LAN2.
# Usage: dhcp-lan.sh
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_root "$@"

LEASE_FILE="${DHCP_LEASEFILE:-/var/lib/misc/dnsmasq.leases}"
LAN_ADDR="${LAN_ADDR:-192.168.50.1}"
LAN_CIDR="${LAN_CIDR:-${LAN_ADDR}/24}"
now="$(date +%s)"
ok_svc=0
ok_addr=0
ok_cfg=0
leases_active=0
leases_total=0
neigh_n=0

echo "===== DHCP-LAN $(ts) ====="
netlog TEST_START "Проверка DHCP/LAN" iface="${LAN_IF}" addr="${LAN_ADDR}"

echo "-- service --"
if systemctl is-active --quiet dnsmasq; then
  ok_svc=1
  echo "dnsmasq: active"
else
  echo "dnsmasq: $(systemctl is-active dnsmasq 2>/dev/null || echo unknown)"
fi

echo "-- LAN address --"
if ip -4 addr show "$LAN_IF" 2>/dev/null | grep -q "inet ${LAN_ADDR}/"; then
  ok_addr=1
  echo "${LAN_IF}: ${LAN_ADDR} OK"
else
  echo "${LAN_IF}: нет ${LAN_ADDR} ($(ip -4 -br addr show "$LAN_IF" 2>/dev/null || echo missing))"
fi

echo "-- config --"
if [[ -f /etc/dnsmasq.d/50-pc-router-lan.conf ]] \
  && grep -qE '^dhcp-range=' /etc/dnsmasq.d/50-pc-router-lan.conf; then
  ok_cfg=1
  grep -E '^(interface|dhcp-range|dhcp-option)=' /etc/dnsmasq.d/50-pc-router-lan.conf || true
else
  echo "(нет /etc/dnsmasq.d/50-pc-router-lan.conf или dhcp-range)"
fi

echo "-- leases (active) --"
if [[ -f "$LEASE_FILE" ]]; then
  while read -r exp mac ip host rest; do
    [[ -z "${exp:-}" || "$exp" == \#* ]] && continue
    [[ ! "$exp" =~ ^[0-9]+$ ]] && continue
    leases_total=$((leases_total + 1))
    if (( exp == 0 || exp > now )); then
      leases_active=$((leases_active + 1))
      left="inf"
      if (( exp > 0 )); then
        left="$(( (exp - now) / 60 ))m"
      fi
      echo "  ${ip:-?}  ${mac:-?}  host=${host:-*}  left=${left}"
    fi
  done <"$LEASE_FILE"
else
  echo "(нет $LEASE_FILE)"
fi
echo "leases_active=${leases_active} leases_total=${leases_total}"

echo "-- neigh on ${LAN_IF} --"
while read -r _ip rest; do
  [[ -z "${_ip:-}" ]] && continue
  # REACHABLE/STALE/DELAY — «видели»; FAILED пропускаем
  if echo "$rest" | grep -Eq 'REACHABLE|STALE|DELAY|PROBE|PERMANENT'; then
    neigh_n=$((neigh_n + 1))
    echo "  ${_ip}  ${rest}"
  fi
done < <(ip -4 neigh show dev "$LAN_IF" 2>/dev/null || true)
echo "neigh_seen=${neigh_n}"

echo "-- summary --"
echo "dnsmasq=${ok_svc} lan_addr=${ok_addr} dhcp_cfg=${ok_cfg} clients_lease=${leases_active} neigh=${neigh_n}"
netlog TEST_END "DHCP/LAN" \
  dnsmasq="$ok_svc" lan_addr="$ok_addr" cfg="$ok_cfg" \
  leases="$leases_active" neigh="$neigh_n"

if [[ "$ok_svc" -eq 1 && "$ok_addr" -eq 1 && "$ok_cfg" -eq 1 ]]; then
  echo "PASS dhcp-lan clients=${leases_active} neigh=${neigh_n}"
  exit 0
fi
echo "FAIL dhcp-lan (dnsmasq=${ok_svc} addr=${ok_addr} cfg=${ok_cfg})"
exit 1
