#!/usr/bin/env bash
# Ускоренная эскалация outage → REBOOT_DRY (без реальной перезагрузки).
# Блокирует default-пинг и ждёт REBOOT_DRY в логе (~1–2 мин вместо часов).
# Usage: outage-escalation.sh [max_wait_sec]
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_root "$@"

MAX_WAIT="${1:-180}"
LOG=/tmp/systema-test-outage-dry.log
exec > >(tee "$LOG") 2>&1
OUTAGE_FILE="${REBOOT_STATE_DIR:-$SYSTEMA_ROUTER_ROOT/state}/outage.state"
OUTAGE_BAK=/run/systema-router/outage.state.testbak
saw_dry=0

cleanup() {
  echo "===== CLEANUP $(ts) ====="
  # снять blackhole / icmp drop
  ip route del blackhole 8.8.8.8 2>/dev/null || true
  ip route del blackhole 1.1.1.1 2>/dev/null || true
  iptables -D OUTPUT -d 8.8.8.8 -p icmp -j DROP 2>/dev/null || true
  iptables -D OUTPUT -d 1.1.1.1 -p icmp -j DROP 2>/dev/null || true
  restore_wan
  clear_icmp_drop_lte
  test_env_end
  if [[ -f "$OUTAGE_BAK" ]]; then
    mv -f "$OUTAGE_BAK" "$OUTAGE_FILE"
  else
    # сбросить тестовый outage
    rm -f "$OUTAGE_FILE"
  fi
  # один прогон failsafe для OUTAGE_CLEAR
  "$SYSTEMA_ROUTER_ROOT/scripts/network-failsafe.sh" 2>/dev/null || true
  snap AFTER_CLEANUP
  netlog TEST_END "outage-escalation завершён" reboot_dry="$saw_dry"
}
trap cleanup EXIT

echo "===== OUTAGE-DRY START $(ts) max_wait=${MAX_WAIT}s ====="
netlog TEST_START "Сценарий outage-escalation DRY" max_wait_s="$MAX_WAIT"

[[ -f "$OUTAGE_FILE" ]] && cp -a "$OUTAGE_FILE" "$OUTAGE_BAK" || rm -f "$OUTAGE_BAK"
# Чистый старт эскалации
cat >"$OUTAGE_FILE" <<EOF
level=0
wait_started=0
last_reboot=0
outage_since=0
EOF

test_env_begin "$TESTS_ROOT/fixtures/fast-outage.env"
snap BEFORE

echo ">>> block ping targets (simulate total outage)"
ip route replace blackhole 8.8.8.8 2>/dev/null || true
ip route replace blackhole 1.1.1.1 2>/dev/null || true
iptables -I OUTPUT -d 8.8.8.8 -p icmp -j DROP 2>/dev/null || true
iptables -I OUTPUT -d 1.1.1.1 -p icmp -j DROP 2>/dev/null || true
# WAN hard-down тоже (как при обрыве)
touch /tmp/hold-wan-down
ip link set "$WAN_IF" down 2>/dev/null || true
clear_icmp_drop_lte
iptables -I OUTPUT -o "$LTE_IF" -p icmp -j DROP 2>/dev/null || true

deadline=$(( $(date +%s) + MAX_WAIT ))
while (( $(date +%s) < deadline )); do
  "$SYSTEMA_ROUTER_ROOT/scripts/network-failsafe.sh" 2>/dev/null || true
  if log_tail 40 'REBOOT_DRY' | grep -q REBOOT_DRY; then
    saw_dry=1
    echo ">>> REBOOT_DRY seen"
    log_tail 10 'REBOOT_DRY|OUTAGE_'
    break
  fi
  echo "... waiting failsafe/outage ($(ts))"
  cat "$OUTAGE_FILE" 2>/dev/null || true
  sleep 15
done

snap AFTER
if [[ "$saw_dry" -eq 1 ]]; then
  echo "PASS outage-escalation (REBOOT_DRY)"
  exit 0
fi
# Эскалация могла пройти (level/last_reboot), а запись REBOOT_DRY — не попасть в хвост лога
if [[ -f "$OUTAGE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$OUTAGE_FILE" || true
  if [[ "${level:-0}" -gt 0 && "${last_reboot:-0}" -gt 0 ]]; then
    echo "PASS outage-escalation (level=$level last_reboot=$last_reboot; REBOOT_DRY missed in log tail)"
    exit 0
  fi
fi
echo "FAIL: не увидели REBOOT_DRY за ${MAX_WAIT}s"
log_tail 40 'OUTAGE_|REBOOT|FAILSAFE'
exit 1
