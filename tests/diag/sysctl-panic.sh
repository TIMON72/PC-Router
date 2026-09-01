#!/usr/bin/env bash
# Проверка sysctl-страховки: lockup→panic→reboot (без реального crash).
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_root "$@"

SYSCTL_FILE=/etc/sysctl.d/99-systema-router.conf
fail=0

check_eq() {
  local key="$1" want="$2" got
  got="$(sysctl -n "$key" 2>/dev/null || echo missing)"
  if [[ "$got" == "$want" ]]; then
    echo "OK  $key=$got"
  else
    echo "FAIL $key want=$want got=$got"
    fail=1
  fi
}

echo "===== sysctl-panic ====="

if [[ -f "$SYSCTL_FILE" ]]; then
  echo "OK  file $SYSCTL_FILE"
else
  echo "FAIL missing $SYSCTL_FILE (нужен upgrade/install)"
  fail=1
fi

check_eq net.ipv4.ip_forward 1
check_eq kernel.softlockup_panic 1
check_eq kernel.hardlockup_panic 1
check_eq kernel.hung_task_panic 1
check_eq kernel.panic_on_oops 1
check_eq kernel.panic 10

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL sysctl-panic"
  exit 1
fi
echo "PASS sysctl-panic"
exit 0
