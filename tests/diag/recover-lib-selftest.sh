#!/usr/bin/env bash
# Самопроверка lib/lte-modem-recover.sh без железа (stage / USB generation / APN gate).
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_root "$@"

TMP="$(mktemp -d /tmp/pc-router-recover-selftest.XXXXXX)"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

export NETLOG_STATE_DIR="$TMP/run"
export REBOOT_STATE_DIR="$TMP/state"
export APN_LAST_FILE="$TMP/state/apn.last"
mkdir -p "$NETLOG_STATE_DIR" "$REBOOT_STATE_DIR"

# shellcheck disable=SC1091
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/lte-modem-recover.sh"

if ! type lte_apn_next_allowed >/dev/null 2>&1; then
  echo "FAIL: lte_apn_next_allowed missing — обновите scripts/lib/lte-modem-recover.sh"
  exit 1
fi

# Управление «присутствием» модема отдельно от state-файла (его пишет tick)
PRESENT_FLAG=1
lte_modem_present() { [[ "${PRESENT_FLAG}" == "1" ]]; }

fail=0
check() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    echo "OK  $name"
  else
    echo "FAIL $name ($cond)"
    fail=1
  fi
}

echo "===== recover-lib-selftest ====="
lte_usb_generation_set 0
check "gen start 0" '[[ "$(lte_usb_generation)" == "0" ]]'

PRESENT_FLAG=1
r1="$(lte_usb_presence_tick)"
check "first tick stable" '[[ "$r1" == "stable" ]]'

PRESENT_FLAG=0
r2="$(lte_usb_presence_tick)"
check "unplug missing" '[[ "$r2" == "missing" ]]'

PRESENT_FLAG=1
r3="$(lte_usb_presence_tick)"
check "replug reseat" '[[ "$r3" == "reseat" ]]'
check "gen bumped" '[[ "$(lte_usb_generation)" -ge 1 ]]'
check "wide after reseat" 'lte_apn_wide_get'
check "reseat flag" '[[ -f "$LTE_USB_RESEAT_FLAG" ]]'

lte_recover_stage_set 0
check "stage 0" '[[ "$(lte_recover_stage_get)" == "0" ]]'
lte_recover_stage_fails_bump >/dev/null
lte_recover_stage_fails_bump >/dev/null
check "stage fails 2" '[[ "$(lte_recover_stage_fails_get)" == "2" ]]'
lte_recover_stage_set 2
check "stage set resets fails" '[[ "$(lte_recover_stage_fails_get)" == "0" ]]'

lte_apn_wide_set 0
rm -f "$LTE_USB_RESEAT_FLAG"
echo internet >"$APN_LAST_FILE"
lte_mark_apn_next_ts
export APN_NEXT_COOLDOWN_SEC=86400
check "narrow cooldown blocks" '! lte_apn_next_allowed'
lte_apn_wide_set 1
check "wide allows next" 'lte_apn_next_allowed'

if [[ "$fail" -eq 0 ]]; then
  echo "PASS recover-lib-selftest"
  exit 0
fi
echo "FAIL recover-lib-selftest"
exit 1
