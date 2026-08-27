#!/usr/bin/env bash
# WAN down + VPN killed → VPN must recover on LTE without WAN
# (soft cold-boot: failover / ppp-ipup restart OpenVPN).
# Usage: vpn-lte-boot.sh [deadline_sec]
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_root "$@"

DEADLINE_SEC="${1:-150}"
LOG=/tmp/systema-test-vpn-lte-boot.log
exec > >(tee "$LOG") 2>&1

ok_lte=0
ok_vpn=0

vpn_ok() {
  if [[ -n "${VPN_PING_HOST:-}" ]]; then
    ping -c 1 -W 3 "$VPN_PING_HOST" >/dev/null 2>&1
  else
    ip -4 addr show "$VPN_IF" 2>/dev/null | grep -q inet
  fi
}

cleanup() {
  echo "===== CLEANUP $(ts) ====="
  restore_wan
  test_env_end
  systemctl start "$LTE_UNIT" 2>/dev/null || true
  systemctl start lte-failover.service 2>/dev/null || true
  if [[ "${EDGE_MODE:-vpn}" == "vpn" ]]; then
    systemctl start "$OPENVPN_UNIT" 2>/dev/null || true
  fi
  snap AFTER_CLEANUP
  netlog TEST_END "vpn-lte-boot завершён" lte_ok="$ok_lte" vpn_ok="$ok_vpn"
}
trap cleanup EXIT

if [[ "${EDGE_MODE:-vpn}" != "vpn" ]]; then
  skip_test "EDGE_MODE=${EDGE_MODE:-} (need vpn)"
fi

echo "===== VPN-LTE-BOOT START $(ts) deadline=${DEADLINE_SEC}s ====="
require_uplinks vpn lte
netlog TEST_START "Сценарий vpn-lte-boot" deadline_s="$DEADLINE_SEC"
test_env_begin "$TESTS_ROOT/fixtures/fast-failover.env"
systemctl start "$LTE_UNIT" || true
sleep 3
snap BEFORE

systemd-run --unit=systema-wan-restore-vpnboot --on-active="${DEADLINE_SEC}s" \
  /bin/bash -c 'rm -f /tmp/hold-wan-down; ip link set enp3s0 up; networkctl up enp3s0; logger -t systema-router SAFE_TEST_DEADLINE_RESTORE' \
  2>/dev/null || (
    ( sleep "$DEADLINE_SEC"; restore_wan ) &
  )

echo ">>> WAN down"
touch /tmp/hold-wan-down
ip link set "$WAN_IF" down 2>/dev/null || true
netlog TEST_HOLD "WAN удержан down (vpn-lte-boot)" max_s="$DEADLINE_SEC"

deadline_ts=$(( $(date +%s) + DEADLINE_SEC ))
while (( $(date +%s) < deadline_ts )); do
  assert_uplinks_still lte
  if on_lte_path && ping -I "$LTE_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    ok_lte=1
    echo ">>> LTE path OK"
    snap ON_LTE
    break
  fi
  sleep 3
done

if [[ "$ok_lte" -ne 1 ]]; then
  echo "FAIL: не дождались LTE за ${DEADLINE_SEC}s"
  snap FAIL_NO_LTE
  exit 1
fi

echo ">>> stop OpenVPN (имитация незавершённого cold-boot VPN)"
systemctl stop "$OPENVPN_UNIT" 2>/dev/null || true
sleep 2
vpn_ok && { echo "FAIL: VPN всё ещё up после stop"; snap FAIL_VPN_STILL_UP; exit 1; }
echo ">>> VPN down confirmed"

echo ">>> restart LTE → ppp-ip-up должен поднять VPN (WAN всё ещё down)"
systemctl restart "$LTE_UNIT" 2>/dev/null || true
netlog TEST_STEP "LTE restart для ppp-ipup VPN" unit="$LTE_UNIT"

recover_deadline=$(( $(date +%s) + DEADLINE_SEC ))
# не выходим за общий deadline теста
if (( recover_deadline > deadline_ts )); then
  recover_deadline=$deadline_ts
fi

while (( $(date +%s) < recover_deadline )); do
  assert_uplinks_still lte
  if ping -I "$LTE_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && vpn_ok; then
    # WAN всё ещё должен быть down
    if [[ -f /tmp/hold-wan-down ]] || [[ "$(cat /sys/class/net/${WAN_IF}/operstate 2>/dev/null || echo down)" != "up" ]]; then
      ok_vpn=1
      echo ">>> VPN recovered on LTE (WAN still down)"
      snap VPN_ON_LTE
      break
    fi
  fi
  sleep 3
done

if [[ "$ok_vpn" -ne 1 ]]; then
  echo "FAIL: VPN не поднялся на LTE при WAN down за ${DEADLINE_SEC}s"
  snap FAIL_NO_VPN
  log_tail 40 "VPN_RESTART|LTE_IPUP|PATH_SWITCH|VPN_"
  exit 1
fi

echo "PASS vpn-lte-boot lte=$ok_lte vpn=$ok_vpn"
exit 0
