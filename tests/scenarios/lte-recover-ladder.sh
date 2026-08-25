#!/usr/bin/env bash
# Лестница LTE recovery: WAN hold → path=lte → ICMP DROP на ppp0.
# Ожидаем ppp_keep_apn, затем при низком LTE_RECOVER_PPP_TRIES — cfun и/или usb_reset.
# APN next при большом APN_NEXT_COOLDOWN_SEC за окно наблюдения не должен появиться.
# Usage: lte-recover-ladder.sh [observe_sec]
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_root "$@"

OBSERVE_SEC="${1:-180}"
LOG=/tmp/systema-test-lte-recover-ladder.log
exec > >(tee "$LOG") 2>&1

saw_ppp=0
saw_cfun=0
saw_usb=0
saw_apn=0
HOLD_WAN=0

cleanup() {
  echo "===== CLEANUP $(ts) ====="
  clear_icmp_drop_lte
  if [[ "$HOLD_WAN" -eq 1 ]]; then
    rm -f /tmp/hold-wan-down
    ip link set "$WAN_IF" up 2>/dev/null || true
    networkctl up "$WAN_IF" 2>/dev/null || true
  fi
  test_env_end
  snap AFTER_CLEANUP
  netlog TEST_END "lte-recover-ladder завершён" \
    ppp="$saw_ppp" cfun="$saw_cfun" usb="$saw_usb" apn="$saw_apn"
}
trap cleanup EXIT

echo "===== LTE-RECOVER-LADDER START $(ts) observe=${OBSERVE_SEC}s ====="
netlog TEST_START "Сценарий lte-recover-ladder" observe_s="$OBSERVE_SEC"

test_env_begin "$TESTS_ROOT/fixtures/fast-failover.env" \
  "LTE_RECOVER_PPP_TRIES=2" \
  "LTE_RECOVER_CFUN_TRIES=1" \
  "LTE_RECOVER_USB_TRIES=1" \
  "APN_NEXT_AFTER_FAILS=2" \
  "APN_NEXT_COOLDOWN_SEC=86400" \
  "LTE_RESTART_COOLDOWN=20" \
  "CHECK_INTERVAL=3" \
  "FAIL_THRESHOLD=2"
# Cooldown: без next_ts первый apn_next всегда разрешён. Wide/reseat обходят cooldown.
mkdir -p /run/systema-router
APN_LAST="${APN_LAST_FILE:-$SYSTEMA_ROUTER_ROOT/state/apn.last}"
if [[ ! -s "$APN_LAST" ]]; then
  echo "internet" >"$APN_LAST"
fi
date +%s >/run/systema-router/lte.apn.next_ts
rm -f /run/systema-router/lte.apn.wide /run/systema-router/usb.reseat \
  /run/systema-router/usb.reset.hold /run/systema-router/usb.missing_since 2>/dev/null || true
sleep 2

# Уводим на LTE, чтобы recovery реально крутился
if [[ "$(cat /sys/class/net/${WAN_IF}/operstate 2>/dev/null || echo down)" == "up" ]]; then
  echo ">>> hold WAN down to force LTE path"
  touch /tmp/hold-wan-down
  HOLD_WAN=1
  ip link set "$WAN_IF" down 2>/dev/null || true
  netlog TEST_HOLD "WAN down for recover-ladder" iface="$WAN_IF"
fi

# Ждём path=lte (не только ping ppp0 — иначе path может остаться wan)
deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < deadline )); do
  if on_lte_path; then
    echo ">>> on LTE path"
    break
  fi
  sleep 3
done
if ! on_lte_path; then
  echo "WARN: path ещё не lte, продолжаем по ping LTE"
fi
snap BEFORE_DROP

if ! ping -I "$LTE_IF" -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
  echo "FAIL: LTE не пингуется до DROP"
  snap FAIL_NO_LTE
  exit 1
fi

echo ">>> DROP icmp on $LTE_IF"
iptables -I OUTPUT -o "$LTE_IF" -p icmp -j DROP
iptables -I INPUT -i "$LTE_IF" -p icmp -j DROP
# Ещё раз узкий режим прямо перед soft-fail (после ожидания LTE мог появиться wide)
date +%s >/run/systema-router/lte.apn.next_ts
rm -f /run/systema-router/lte.apn.wide /run/systema-router/usb.reseat \
  /run/systema-router/usb.reset.hold /run/systema-router/usb.missing_since 2>/dev/null || true
OBS_TOKEN="LADDER_OBS_$$_$RANDOM"
netlog TEST_HOLD "ICMP DROP на LTE для recover-ladder" iface="$LTE_IF" token="$OBS_TOKEN"

FAILOVER_LOG="${LOG_FILE:-$SYSTEMA_ROUTER_ROOT/lte-failover.log}"
NETLOG="${NETLOG_FILE:-$SYSTEMA_ROUTER_ROOT/logs.log}"
echo "$(date -Iseconds 2>/dev/null || date) $OBS_TOKEN" >>"$FAILOVER_LOG" 2>/dev/null || true

# Только строки ПОСЛЕ маркера этого прогона (иначе ловим apn_next из прошлых тестов)
after_mark() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk -v tok="$OBS_TOKEN" 'found { print; next } index($0, tok) { found=1 }' "$file" 2>/dev/null || true
}

deadline=$(( $(date +%s) + OBSERVE_SEC ))
while (( $(date +%s) < deadline )); do
  slice="$(after_mark "$NETLOG")"
  echo "$slice" | grep 'LTE_RESTART' | grep -q 'reason=apn_next' && saw_apn=1
  echo "$slice" | grep -q 'ppp_keep_apn' && saw_ppp=1
  echo "$slice" | grep -q 'cfun_keep_apn' && saw_cfun=1
  echo "$slice" | grep -q 'usb_reset_keep_apn' && saw_usb=1
  flog="$(after_mark "$FAILOVER_LOG")"
  echo "$flog" | grep -q 'ppp_keep_apn' && saw_ppp=1
  echo "$flog" | grep -q 'cfun_keep_apn' && saw_cfun=1
  echo "$flog" | grep -q 'usb_reset_keep_apn' && saw_usb=1
  echo "$flog" | grep -E 'Перезапуск LTE \(apn_next\)' >/dev/null && saw_apn=1
  sleep 5
done

snap AFTER
echo "saw_ppp=$saw_ppp saw_cfun=$saw_cfun saw_usb=$saw_usb saw_apn=$saw_apn"

if [[ "$saw_ppp" -ne 1 ]]; then
  echo "FAIL: не увидели ppp_keep_apn"
  exit 1
fi
if [[ "$saw_apn" -eq 1 ]]; then
  echo "FAIL: apn_next не должен был сработать при APN_NEXT_COOLDOWN_SEC=86400"
  exit 1
fi
# CFUN/USB — желательная эскалация; для PASS достаточно PPP keep без APN next
if [[ "$OBSERVE_SEC" -ge 100 && "$saw_cfun" -eq 0 && "$saw_usb" -eq 0 ]]; then
  echo "WARN: за ${OBSERVE_SEC}s не увидели cfun/usb (cooldown/железа), но ppp_keep_apn был"
fi

echo "PASS lte-recover-ladder (ppp=$saw_ppp cfun=$saw_cfun usb=$saw_usb apn=$saw_apn)"
exit 0
