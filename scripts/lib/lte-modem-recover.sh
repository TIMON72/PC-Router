#!/usr/bin/env bash
# Восстановление USB-LTE data path: USB generation, CFUN, USB reset.
# shellcheck shell=bash
# Подключается после load-config.sh (нужны SYSTEMA_ROUTER_ROOT, NETLOG_STATE_DIR, …).

: "${NETLOG_STATE_DIR:=/run/systema-router}"
: "${REBOOT_STATE_DIR:=${SYSTEMA_ROUTER_ROOT:-/home/admin/PC-Router}/state}"
: "${LTE_MODEM_DEV:=/dev/ttyUSB0}"
: "${LTE_MODEM_AT_DEV:=}"
: "${LTE_UNIT:=lte.service}"

LTE_USB_GEN_FILE="${LTE_USB_GEN_FILE:-$REBOOT_STATE_DIR/usb.generation}"
LTE_USB_PRESENT_FILE="${LTE_USB_PRESENT_FILE:-$NETLOG_STATE_DIR/usb.present}"
LTE_USB_RESEAT_FLAG="${LTE_USB_RESEAT_FLAG:-$NETLOG_STATE_DIR/usb.reseat}"
# Пока идёт наш USB reset — presence_tick не считает missing→present как «смена SIM»
LTE_USB_RESET_HOLD_FILE="${LTE_USB_RESET_HOLD_FILE:-$NETLOG_STATE_DIR/usb.reset.hold}"
# Момент, когда модем впервые пропал (для debounce ложного reseat при restart/CFUN)
LTE_USB_MISSING_SINCE_FILE="${LTE_USB_MISSING_SINCE_FILE:-$NETLOG_STATE_DIR/usb.missing_since}"
# Сколько секунд «нет модема» считать реальным извлечением USB/SIM
LTE_USB_RESEAT_MIN_MISSING_SEC="${LTE_USB_RESEAT_MIN_MISSING_SEC:-12}"
LTE_RECOVER_STAGE_FILE="${LTE_RECOVER_STAGE_FILE:-$NETLOG_STATE_DIR/lte.recover.stage}"
LTE_RECOVER_STAGE_FAILS_FILE="${LTE_RECOVER_STAGE_FAILS_FILE:-$NETLOG_STATE_DIR/lte.recover.stage_fails}"
LTE_APN_WIDE_FILE="${LTE_APN_WIDE_FILE:-$NETLOG_STATE_DIR/lte.apn.wide}"
LTE_LAST_APN_NEXT_TS_FILE="${LTE_LAST_APN_NEXT_TS_FILE:-$NETLOG_STATE_DIR/lte.apn.next_ts}"
LTE_IMSI_CACHE="${LTE_IMSI_CACHE:-$NETLOG_STATE_DIR/imsi.cache}"

mkdir -p "$NETLOG_STATE_DIR" "$REBOOT_STATE_DIR" 2>/dev/null || true

lte_modem_present() {
  local d="${LTE_MODEM_DEV:-/dev/ttyUSB0}"
  [[ -e "$d" ]] || ls /dev/ttyUSB* >/dev/null 2>&1
}

lte_modem_at_candidates() {
  local d
  for d in "$LTE_MODEM_AT_DEV" "$LTE_MODEM_DEV" /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyUSB3 /dev/ttyUSB0 /dev/ttyACM0; do
    [[ -n "$d" && -e "$d" ]] && echo "$d"
  done | awk 'NF && !seen[$0]++'
}

# sysfs USB-устройство (…/1-2) по tty
lte_modem_usb_sysfs() {
  local tty base name parent
  tty="${LTE_MODEM_DEV:-/dev/ttyUSB0}"
  tty="${tty#/dev/}"
  [[ -e "/sys/class/tty/$tty/device" ]] || {
    # любой ttyUSB*
    local t
    for t in /sys/class/tty/ttyUSB*; do
      [[ -e "$t/device" ]] || continue
      tty="$(basename "$t")"
      break
    done
  }
  [[ -e "/sys/class/tty/$tty/device" ]] || return 1
  base="$(readlink -f "/sys/class/tty/$tty/device" 2>/dev/null)" || return 1
  # …/1-2:1.0 → …/1-2
  parent="$(dirname "$base")"
  name="$(basename "$parent")"
  if [[ "$name" == *:* ]]; then
    parent="$(dirname "$parent")"
  fi
  [[ -e "$parent/idVendor" ]] || return 1
  echo "$parent"
}

lte_usb_generation() {
  local g=0
  [[ -f "$LTE_USB_GEN_FILE" ]] && g="$(tr -dc '0-9' <"$LTE_USB_GEN_FILE")"
  [[ -n "$g" ]] || g=0
  echo "$g"
}

lte_usb_generation_set() {
  echo "$1" >"$LTE_USB_GEN_FILE"
}

lte_usb_generation_bump() {
  local g
  g="$(lte_usb_generation)"
  g=$((g + 1))
  lte_usb_generation_set "$g"
  echo "$g"
}

lte_apn_wide_set() {
  echo "${1:-1}" >"$LTE_APN_WIDE_FILE"
}

lte_apn_wide_get() {
  [[ -f "$LTE_APN_WIDE_FILE" ]] && [[ "$(tr -d ' \n\r' <"$LTE_APN_WIDE_FILE")" == "1" ]]
}

lte_has_last_apn() {
  local f="${APN_LAST_FILE:-$REBOOT_STATE_DIR/apn.last}"
  [[ -n "$f" && -s "$f" ]]
}

lte_recover_stage_get() {
  local s=0
  [[ -f "$LTE_RECOVER_STAGE_FILE" ]] && s="$(tr -dc '0-9' <"$LTE_RECOVER_STAGE_FILE")"
  [[ -n "$s" ]] || s=0
  echo "$s"
}

lte_recover_stage_set() {
  echo "$1" >"$LTE_RECOVER_STAGE_FILE"
  echo 0 >"$LTE_RECOVER_STAGE_FAILS_FILE"
}

lte_recover_stage_fails_get() {
  local n=0
  [[ -f "$LTE_RECOVER_STAGE_FAILS_FILE" ]] && n="$(tr -dc '0-9' <"$LTE_RECOVER_STAGE_FAILS_FILE")"
  [[ -n "$n" ]] || n=0
  echo "$n"
}

lte_recover_stage_fails_bump() {
  local n
  n="$(lte_recover_stage_fails_get)"
  n=$((n + 1))
  echo "$n" >"$LTE_RECOVER_STAGE_FAILS_FILE"
  echo "$n"
}

lte_recover_reset_progress() {
  lte_recover_stage_set 0
  rm -f "$LTE_USB_RESEAT_FLAG" 2>/dev/null || true
}

# Тик присутствия модема: missing→present = reseat (смена SIM / переподключение USB).
# Краткий blip tty при systemctl restart / CFUN — не reseat (debounce).
# echo reseat|stable|missing
lte_usb_presence_tick() {
  local now=0 prev="" since=0 age=0 min_miss
  lte_modem_present && now=1
  [[ -f "$LTE_USB_PRESENT_FILE" ]] && prev="$(tr -dc '01' <"$LTE_USB_PRESENT_FILE")"
  echo "$now" >"$LTE_USB_PRESENT_FILE"
  min_miss="${LTE_USB_RESEAT_MIN_MISSING_SEC:-12}"
  [[ "$min_miss" =~ ^[0-9]+$ ]] || min_miss=12

  # Наш recovery USB reset — не wide/reseat
  if [[ -f "$LTE_USB_RESET_HOLD_FILE" ]]; then
    rm -f "$LTE_USB_MISSING_SINCE_FILE" 2>/dev/null || true
    if [[ "$now" -eq 0 ]]; then
      echo "missing"
    else
      echo "stable"
    fi
    return 0
  fi

  if [[ "$now" -eq 0 ]]; then
    if [[ ! -f "$LTE_USB_MISSING_SINCE_FILE" ]]; then
      date +%s >"$LTE_USB_MISSING_SINCE_FILE"
    fi
    echo "missing"
    return 0
  fi

  # Модем снова есть
  if [[ -f "$LTE_USB_MISSING_SINCE_FILE" ]]; then
    since="$(tr -dc '0-9' <"$LTE_USB_MISSING_SINCE_FILE")"
    [[ -n "$since" ]] || since=0
    age=$(( $(date +%s) - since ))
    rm -f "$LTE_USB_MISSING_SINCE_FILE" 2>/dev/null || true
    if [[ "$since" -gt 0 && "$age" -ge "$min_miss" ]]; then
      lte_usb_generation_bump >/dev/null
      lte_apn_wide_set 1
      lte_recover_stage_set 0
      rm -f "$LTE_IMSI_CACHE" 2>/dev/null || true
      touch "$LTE_USB_RESEAT_FLAG"
      type netlog >/dev/null 2>&1 && netlog USB_RESEAT "USB-модем переподключён (возможна смена SIM)" \
        generation="$(lte_usb_generation)" missing_sec="$age" || true
      echo "reseat"
      return 0
    fi
    # короткий blip — игнор
    echo "stable"
    return 0
  fi

  if [[ -z "$prev" ]]; then
    echo "stable"
    return 0
  fi
  echo "stable"
}

lte_wait_modem() {
  local max="${1:-90}" w
  for ((w = 1; w <= max; w++)); do
    if lte_modem_present; then
      echo "$w"
      return 0
    fi
    sleep 1
  done
  return 1
}

# AT+CFUN bounce на AT-порту (radio soft-reset)
lte_modem_cfun_bounce() {
  local dev="" ok=0
  touch "$LTE_USB_RESET_HOLD_FILE"
  while read -r dev; do
    [[ -e "$dev" ]] || continue
    if /usr/sbin/chat -t 8 \
      "" "AT" \
      "OK" "AT+CFUN=0" \
      "OK" "" \
      <"$dev" >"$dev" 2>/dev/null; then
      sleep "${LTE_CFUN_DOWN_SEC:-3}"
      if /usr/sbin/chat -t 12 \
        "" "AT" \
        "OK" "AT+CFUN=1" \
        "OK" "" \
        <"$dev" >"$dev" 2>/dev/null; then
        ok=1
        type netlog >/dev/null 2>&1 && netlog LTE_CFUN "Radio CFUN bounce OK" modem="$dev" || true
        break
      fi
    fi
  done < <(lte_modem_at_candidates)
  if [[ "$ok" -eq 0 ]]; then
    rm -f "$LTE_USB_RESET_HOLD_FILE" 2>/dev/null || true
    type netlog >/dev/null 2>&1 && netlog LTE_CFUN_FAIL "CFUN bounce не удался" || true
    return 1
  fi
  sleep "${LTE_CFUN_UP_SEC:-5}"
  echo 1 >"$LTE_USB_PRESENT_FILE"
  rm -f "$LTE_USB_MISSING_SINCE_FILE" "$LTE_USB_RESET_HOLD_FILE" 2>/dev/null || true
  return 0
}

# Сброс USB-устройства (ближе к power-cycle порта, чем reboot ОС)
lte_modem_usb_reset() {
  local sys path busdev ok=0
  touch "$LTE_USB_RESET_HOLD_FILE"
  sys="$(lte_modem_usb_sysfs 2>/dev/null || true)"
  if [[ -n "$sys" && -e "$sys/authorized" ]]; then
    type netlog >/dev/null 2>&1 && netlog LTE_USB_RESET "USB authorized 0→1" path="$sys" || true
    echo 0 >"$sys/authorized" 2>/dev/null || true
    sleep "${LTE_USB_RESET_DOWN_SEC:-2}"
    echo 1 >"$sys/authorized" 2>/dev/null || true
    ok=1
  fi

  if command -v usbreset >/dev/null 2>&1 && [[ -n "$sys" ]]; then
    local vend prod
    vend="$(tr -d ' \n' <"$sys/idVendor" 2>/dev/null || true)"
    prod="$(tr -d ' \n' <"$sys/idProduct" 2>/dev/null || true)"
    if [[ -n "$vend" && -n "$prod" ]]; then
      usbreset "$vend:$prod" 2>/dev/null && ok=1 || true
    fi
  fi

  # Fallback: USBDEVFS_RESET через python, если есть /dev/bus/usb
  if [[ "$ok" -eq 0 && -n "$sys" && -e "$sys/busnum" && -e "$sys/devnum" ]]; then
    local bus num node
    bus="$(tr -d ' \n' <"$sys/busnum")"
    num="$(tr -d ' \n' <"$sys/devnum")"
    node="$(printf '/dev/bus/usb/%03d/%03d' "$bus" "$num")"
    if [[ -e "$node" ]] && command -v python3 >/dev/null 2>&1; then
      if python3 - "$node" <<'PY' 2>/dev/null
import fcntl, os, sys
USBDEVFS_RESET = 21780
path = sys.argv[1]
fd = os.open(path, os.O_WRONLY)
try:
    fcntl.ioctl(fd, USBDEVFS_RESET, 0)
finally:
    os.close(fd)
PY
      then
        ok=1
        type netlog >/dev/null 2>&1 && netlog LTE_USB_RESET "USBDEVFS_RESET OK" node="$node" || true
      fi
    fi
  fi

  if [[ "$ok" -eq 0 ]]; then
    rm -f "$LTE_USB_RESET_HOLD_FILE" 2>/dev/null || true
    type netlog >/dev/null 2>&1 && netlog LTE_USB_RESET_FAIL "USB reset не выполнен" || true
    return 1
  fi
  sleep "${LTE_USB_RESET_UP_SEC:-3}"
  # Не оставляем ложный reseat/wide от нашего reset
  echo 1 >"$LTE_USB_PRESENT_FILE"
  rm -f "$LTE_USB_RESEAT_FLAG" "$LTE_USB_RESET_HOLD_FILE" 2>/dev/null || true
  return 0
}

lte_last_apn_next_ts() {
  local t=0
  [[ -f "$LTE_LAST_APN_NEXT_TS_FILE" ]] && t="$(tr -dc '0-9' <"$LTE_LAST_APN_NEXT_TS_FILE")"
  [[ -n "$t" ]] || t=0
  echo "$t"
}

lte_mark_apn_next_ts() {
  date +%s >"$LTE_LAST_APN_NEXT_TS_FILE"
}

lte_apn_next_allowed() {
  local now last cool
  now="$(date +%s)"
  if lte_apn_wide_get || ! lte_has_last_apn || [[ -f "$LTE_USB_RESEAT_FLAG" ]]; then
    return 0
  fi
  last="$(lte_last_apn_next_ts)"
  cool="${APN_NEXT_COOLDOWN_SEC:-900}"
  [[ $((now - last)) -ge $cool ]]
}
