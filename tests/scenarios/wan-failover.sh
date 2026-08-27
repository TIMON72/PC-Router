#!/usr/bin/env bash
# WAN down → ожидание LTE path → возврат WAN. С обязательным deadline.
# Usage: wan-failover.sh [deadline_sec] [lte_dwell_sec]
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_root "$@"

DEADLINE_SEC="${1:-180}"
LTE_DWELL_SEC="${2:-45}"
LOG=/tmp/systema-test-wan-failover.log
exec > >(tee "$LOG") 2>&1

ok_lte=0
ok_wan=0
vpn_on_lte=0

cleanup() {
  echo "===== CLEANUP $(ts) ====="
  restore_wan
  test_env_end
  systemctl start lte-failover.service 2>/dev/null || true
  if [[ "${EDGE_MODE:-vpn}" == "vpn" ]]; then
    systemctl restart "$OPENVPN_UNIT" 2>/dev/null || true
  fi
  snap AFTER_CLEANUP
  netlog TEST_END "wan-failover завершён" lte_ok="$ok_lte" wan_ok="$ok_wan" vpn_on_lte="$vpn_on_lte"
}
trap cleanup EXIT

echo "===== WAN-FAILOVER START $(ts) deadline=${DEADLINE_SEC}s dwell=${LTE_DWELL_SEC}s ====="
require_uplinks wan lte
netlog TEST_START "Сценарий wan-failover" deadline_s="$DEADLINE_SEC" dwell_s="$LTE_DWELL_SEC"
test_env_begin "$TESTS_ROOT/fixtures/fast-failover.env"
systemctl start "$LTE_UNIT" || true
sleep 3
snap BEFORE

systemd-run --unit=systema-wan-restore --on-active="${DEADLINE_SEC}s" \
  /bin/bash -c 'rm -f /tmp/hold-wan-down; ip link set enp3s0 up; networkctl up enp3s0; logger -t systema-router SAFE_TEST_DEADLINE_RESTORE' \
  2>/dev/null || (
    ( sleep "$DEADLINE_SEC"; restore_wan ) &
  )

echo ">>> WAN down (max ${DEADLINE_SEC}s)"
touch /tmp/hold-wan-down
ip link set "$WAN_IF" down 2>/dev/null || true
netlog TEST_HOLD "WAN удержан down" max_s="$DEADLINE_SEC"

deadline_ts=$(( $(date +%s) + DEADLINE_SEC ))
while (( $(date +%s) < deadline_ts )); do
  assert_uplinks_still lte
  if on_lte_path && ping -I "$LTE_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    ok_lte=1
    echo ">>> LTE path OK"
    snap ON_LTE
    if [[ -n "${VPN_PING_HOST:-}" ]]; then
      ping -c 1 -W 3 "$VPN_PING_HOST" >/dev/null 2>&1 && vpn_on_lte=1
    elif ip -4 addr show "$VPN_IF" 2>/dev/null | grep -q inet; then
      vpn_on_lte=1
    fi
    break
  fi
  sleep 3
done

if [[ "$ok_lte" -ne 1 ]]; then
  echo "FAIL: не дождались LTE за ${DEADLINE_SEC}s"
  snap FAIL_NO_LTE
  exit 1
fi

echo ">>> dwell ${LTE_DWELL_SEC}s on LTE"
sleep "$LTE_DWELL_SEC"

echo ">>> restore WAN"
restore_wan
recover_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < recover_deadline )); do
  # WAN намеренно поднимается — assert_uplinks_still wan здесь даёт ложный FAIL
  if on_wan_path && ping -I "$WAN_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    ok_wan=1
    echo ">>> WAN path OK"
    snap ON_WAN
    break
  fi
  sleep 3
done

[[ "$ok_wan" -eq 1 ]] || { echo "WARN: WAN path не подтверждён за 90s"; snap WARN_WAN; exit 2; }
echo "PASS wan-failover lte=$ok_lte wan=$ok_wan vpn_on_lte=$vpn_on_lte"
exit 0
