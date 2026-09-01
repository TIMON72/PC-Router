#!/usr/bin/env bash
# E2E: kernel panic (sysrq-c) → kernel.panic=N → reboot → VPN + uplink OK.
# Usage: sudo bash tests/run.sh panic-reboot [observe_sec]
# Нужен хотя бы один uplink (WAN или LTE). В suite: группа WAN|LTE.
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck disable=SC1091
source "$TESTS_ROOT/lib/reboot-case.sh"

observe="${1:-180}"
require_root

if [[ "${EDGE_MODE}" != "vpn" ]]; then
  skip_test "EDGE_MODE=$EDGE_MODE (need vpn)"
fi

for kv in \
  "kernel.hardlockup_panic=1" \
  "kernel.softlockup_panic=1" \
  "kernel.hung_task_panic=1" \
  "kernel.panic=10"
do
  key="${kv%%=*}"
  want="${kv#*=}"
  got="$(sysctl -n "$key" 2>/dev/null || true)"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: $key=$got (want $want) — сначала upgrade / diag sysctl-panic"
    exit 1
  fi
done

mode=""
if wan_phys_ok; then
  mode=wan
elif lte_hw_ok; then
  mode=lte
else
  skip_test "no WAN and no LTE for panic-reboot"
fi

echo "===== PANIC-REBOOT START $(date -Is) mode=$mode observe=${observe}s ====="
netlog TEST_START "Сценарий panic-reboot" mode="$mode" observe_s="$observe"

reboot_test_disarm
rm -f "$REBOOT_RESULT" "$REBOOT_PENDING"
: >"$REBOOT_OUT"

case "$mode" in
  wan)
    systemctl stop "$LTE_UNIT" 2>/dev/null || true
    systemctl disable "$LTE_UNIT" 2>/dev/null || true
    restore_wan
    sleep 2
    if ! ping -I "$WAN_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
      echo "FAIL: WAN недоступен до panic-reboot"
      exit 1
    fi
    ;;
  lte)
    systemctl start "$LTE_UNIT" 2>/dev/null || true
    touch /tmp/hold-wan-down
    ip link set "$WAN_IF" down 2>/dev/null || true
    d=$(( $(date +%s) + 90 ))
    lte_ok=0
    while (( $(date +%s) < d )); do
      assert_uplinks_still lte
      if ping -I "$LTE_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        lte_ok=1
        break
      fi
      sleep 3
    done
    if [[ "$lte_ok" -ne 1 ]]; then
      echo "FAIL: LTE недоступен до panic-reboot"
      restore_wan
      exit 1
    fi
    ;;
esac

reboot_test_install_units "$mode" "$observe"
sync
netlog REBOOT_TEST_ARM "Arm panic-reboot" mode="$mode" observe_s="$observe"

echo 1 >/proc/sys/kernel/sysrq
echo ">>> sysrq-trigger c (panic → reboot in ~$(sysctl -n kernel.panic)s, verify mode=$mode)"
sleep 2
echo c >/proc/sysrq-trigger

sleep 30
echo "FAIL: panic/reboot did not happen"
echo 1 >"$REBOOT_RESULT"
reboot_test_disarm
exit 1
