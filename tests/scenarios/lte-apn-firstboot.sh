#!/usr/bin/env bash
# Без apn.last (имитация первого запуска): после PPP-fail должен быстрее уйти в apn_next (wide).
# Usage: lte-apn-firstboot.sh [observe_sec]
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_root "$@"

OBSERVE_SEC="${1:-150}"
LOG=/tmp/systema-test-lte-apn-firstboot.log
exec > >(tee "$LOG") 2>&1

APN_BAK=/run/systema-router/apn.last.testbak
saw_apn=0
HOLD_WAN=0
APN_LAST="${APN_LAST_FILE:-$SYSTEMA_ROUTER_ROOT/state/apn.last}"

wipe_firstboot_state() {
  # Failover на LTE_OK зовёт apn-select success → снова пишет apn.last.
  # Сбрасываем last и recover-stage уже после ICMP DROP, когда success не сработает.
  rm -f "$APN_LAST"
  rm -f /run/systema-router/lte.apn.wide /run/systema-router/lte.recover.stage \
    /run/systema-router/lte.recover.stage_fails /run/systema-router/apn.current \
    /run/systema-router/apn.try.list /run/systema-router/apn.try.idx 2>/dev/null || true
}

cleanup() {
  echo "===== CLEANUP $(ts) ====="
  clear_icmp_drop_lte
  if [[ "$HOLD_WAN" -eq 1 ]]; then
    rm -f /tmp/hold-wan-down
    ip link set "$WAN_IF" up 2>/dev/null || true
    networkctl up "$WAN_IF" 2>/dev/null || true
  fi
  if [[ -f "$APN_BAK" ]]; then
    cp -a "$APN_BAK" "$APN_LAST"
    rm -f "$APN_BAK"
  fi
  test_env_end
  snap AFTER_CLEANUP
  netlog TEST_END "lte-apn-firstboot завершён" apn="$saw_apn"
}
trap cleanup EXIT

echo "===== LTE-APN-FIRSTBOOT START $(ts) ====="
require_uplinks lte
netlog TEST_START "Сценарий lte-apn-firstboot" observe_s="$OBSERVE_SEC"
netlog TEST_START "Сценарий lte-apn-firstboot" observe_s="$OBSERVE_SEC"

mkdir -p /run/systema-router
if [[ -f "$APN_LAST" ]]; then
  cp -a "$APN_LAST" "$APN_BAK"
fi
wipe_firstboot_state

test_env_begin "$TESTS_ROOT/fixtures/fast-failover.env" \
  "LTE_RECOVER_PPP_TRIES=1" \
  "APN_NEXT_AFTER_FAILS=1" \
  "APN_NEXT_COOLDOWN_SEC=1" \
  "LTE_RESTART_COOLDOWN=10" \
  "LTE_RECOVER_WAIT_LOOPS=4" \
  "LTE_RECOVER_WAIT_SLEEP=3" \
  "CHECK_INTERVAL=3" \
  "FAIL_THRESHOLD=2"
sleep 2

if [[ "$(cat /sys/class/net/${WAN_IF}/operstate 2>/dev/null || echo down)" == "up" ]]; then
  touch /tmp/hold-wan-down
  HOLD_WAN=1
  ip link set "$WAN_IF" down 2>/dev/null || true
fi

deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < deadline )); do
  on_lte_path && ping -I "$LTE_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && break
  sleep 3
done
if ! ping -I "$LTE_IF" -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
  echo "FAIL: нет LTE до теста"
  exit 1
fi

# Сначала режем ICMP (чтобы success не пересоздал last), потом снова «первый boot»
iptables -I OUTPUT -o "$LTE_IF" -p icmp -j DROP
iptables -I INPUT -i "$LTE_IF" -p icmp -j DROP
wipe_firstboot_state
echo ">>> firstboot: apn.last сброшен после DROP"

FAILOVER_LOG="${LOG_FILE:-$SYSTEMA_ROUTER_ROOT/lte-failover.log}"
deadline=$(( $(date +%s) + OBSERVE_SEC ))
while (( $(date +%s) < deadline )); do
  if log_tail 150 'LTE_RESTART' | grep -Eq 'reason=apn_next|soft_fail_apn_next'; then
    saw_apn=1
    break
  fi
  if tail -n 80 "$FAILOVER_LOG" 2>/dev/null | grep -q 'apn_next'; then
    saw_apn=1
    break
  fi
  sleep 5
done

echo "saw_apn=$saw_apn"
if [[ "$saw_apn" -ne 1 ]]; then
  echo "FAIL: без apn.last не увидели apn_next"
  exit 1
fi
echo "PASS lte-apn-firstboot"
exit 0
