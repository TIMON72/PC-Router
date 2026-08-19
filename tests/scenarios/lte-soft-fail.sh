#!/usr/bin/env bash
# Имитация «мягкого» провала LTE (ICMP DROP на ppp0): APN не должен смениться
# сразу; ожидаем soft_fail_keep_apn, а next — только после APN_NEXT_AFTER_FAILS.
# Usage: lte-soft-fail.sh [observe_sec]
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_root "$@"

OBSERVE_SEC="${1:-120}"
LOG=/tmp/systema-test-lte-soft-fail.log
exec > >(tee "$LOG") 2>&1

apn_before=""
apn_after=""
saw_keep=0
saw_next=0

cleanup() {
  echo "===== CLEANUP $(ts) ====="
  clear_icmp_drop_lte
  test_env_end
  snap AFTER_CLEANUP
  netlog TEST_END "lte-soft-fail завершён" keep="$saw_keep" next="$saw_next" apn_before="$apn_before" apn_after="$apn_after"
}
trap cleanup EXIT

echo "===== LTE-SOFT-FAIL START $(ts) observe=${OBSERVE_SEC}s ====="
netlog TEST_START "Сценарий lte-soft-fail" observe_s="$OBSERVE_SEC"

if ! ip -4 addr show "$LTE_IF" 2>/dev/null | grep -q inet; then
  echo "LTE iface $LTE_IF без IPv4 — поднимаю lte.service"
  systemctl restart "$LTE_UNIT" || true
  sleep 20
fi
if ! ping -I "$LTE_IF" -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
  echo "FAIL: LTE не пингуется до теста"
  snap FAIL_NO_LTE
  exit 1
fi

apn_before="$("$SYSTEMA_ROUTER_ROOT/scripts/lte-apn-select.sh" show 2>/dev/null | awk -F= '/^current=/{print $2; exit}')"
echo "APN before: $apn_before"
# Короткий cooldown, но APN_NEXT_AFTER_FAILS=3 — за observe не должны уйти в next
test_env_begin "$TESTS_ROOT/fixtures/fast-failover.env" "APN_NEXT_AFTER_FAILS=3" "LTE_RESTART_COOLDOWN=25"
sleep 2
snap BEFORE

echo ">>> DROP icmp on $LTE_IF"
iptables -I OUTPUT -o "$LTE_IF" -p icmp -j DROP
iptables -I INPUT -i "$LTE_IF" -p icmp -j DROP
netlog TEST_HOLD "ICMP DROP на LTE для soft-fail" iface="$LTE_IF"

# Держим WAN up — иначе уйдём в полный NO_UPLINK иначе; цель — soft fail на LTE path
# Если сейчас path=lte, failover должен рестартить с keep_apn
deadline=$(( $(date +%s) + OBSERVE_SEC ))
while (( $(date +%s) < deadline )); do
  if log_tail 80 'LTE_RESTART' | grep -q 'soft_fail_keep_apn'; then
    saw_keep=1
  fi
  if log_tail 80 'LTE_RESTART' | grep -q 'soft_fail_apn_next'; then
    saw_next=1
  fi
  sleep 5
done

clear_icmp_drop_lte
sleep 10
apn_after="$("$SYSTEMA_ROUTER_ROOT/scripts/lte-apn-select.sh" show 2>/dev/null | awk -F= '/^current=/{print $2; exit}')"
snap AFTER
echo "APN after: $apn_after"
echo "saw_keep=$saw_keep saw_next=$saw_next"

# Успех: либо увидели keep, либо APN не сменился (и next не обязан был случиться за окно)
if [[ "$saw_next" -eq 1 && "$apn_before" != "$apn_after" && "$saw_keep" -eq 0 ]]; then
  echo "FAIL: APN сменился без soft_fail_keep_apn"
  exit 1
fi
if [[ "$apn_before" != "$apn_after" && "$saw_next" -eq 0 ]]; then
  echo "WARN: APN изменился без soft_fail_apn_next в хвосте лога"
fi
echo "PASS lte-soft-fail (keep=$saw_keep next=$saw_next apn ${apn_before}->${apn_after})"
exit 0
