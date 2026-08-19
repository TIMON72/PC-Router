#!/usr/bin/env bash
# Инициализация USB LTE-модема: ждём устройство, применяем last/known APN
set -euo pipefail
# shellcheck disable=SC1091
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh"
type netlog >/dev/null 2>&1 || netlog() { :; }

# shellcheck disable=SC1091

MODEM="${LTE_MODEM_DEV:-/dev/ttyUSB0}"
SELECT_BIN="${LTE_APN_SELECT:-$SYSTEMA_ROUTER_ROOT/scripts/lte-apn-select.sh}"
WAIT_SEC="${LTE_MODEM_WAIT_SEC:-90}"

modprobe usbserial 2>/dev/null || true
echo "161c f101" > /sys/bus/usb-serial/drivers/generic/new_id 2>/dev/null || true

found=0
for _ in $(seq 1 "$WAIT_SEC"); do
  if [[ -e "$MODEM" ]] || ls /dev/ttyUSB* >/dev/null 2>&1; then
    found=1
    break
  fi
  sleep 1
done

if [[ $found -eq 0 ]]; then
  echo "WARNING: modem device $MODEM not found after ${WAIT_SEC}s" >&2
  netlog LTE_MODEM_WAIT "Модем не появился" modem="$MODEM" waited_s="$WAIT_SEC"
  # не стартуем pppd без устройства — пусть systemd повторит
  exit 1
fi

if [[ -x "$SELECT_BIN" ]]; then
  # Предпочитаем последний успешный APN (та же SIM с высокой вероятностью)
  "$SELECT_BIN" reapply-last >/dev/null 2>&1 || "$SELECT_BIN" apply >/dev/null 2>&1 || true
else
  /usr/sbin/chat -V -s -t 5 \
    "" "AT" \
    "OK" "AT+CGDCONT=1,\"IP\",\"internet\"" \
    "OK" "AT+CGDCONT=2" \
    "OK" "AT&W" \
    < "$MODEM" > "$MODEM" || true
fi
exit 0
