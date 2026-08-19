#!/usr/bin/env bash
# Выбор APN: по IMSI/оператору + перебор как в роутерах
set -euo pipefail
# shellcheck disable=SC1091
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh"
type netlog >/dev/null 2>&1 || netlog() { :; }

MODEM="${LTE_MODEM_DEV:-/dev/ttyUSB0}"
MODEM_AT="${LTE_MODEM_AT_DEV:-}"
PROFILES="${APN_PROFILES_FILE}"
[[ -f "$PROFILES" ]] || PROFILES="$SYSTEMA_ROUTER_ROOT/conf/apn-profiles.conf"
RUN_DIR="${NETLOG_STATE_DIR}"
LAST_FILE="${APN_LAST_FILE}"
IMSI_CACHE="$RUN_DIR/imsi.cache"
LIST_FILE="$RUN_DIR/apn.try.list"
IDX_FILE="$RUN_DIR/apn.try.idx"
CUR_FILE="$RUN_DIR/apn.current"

mkdir -p "$RUN_DIR" "$(dirname "$LAST_FILE")" 2>/dev/null || true

modem_candidates() {
  local d
  for d in "$MODEM_AT" "$MODEM" /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyUSB3 /dev/ttyUSB0 /dev/ttyACM0; do
    [[ -n "$d" && -e "$d" ]] && echo "$d"
  done | awk 'NF && !seen[$0]++'
}

read_imsi_from_dev() {
  local dev="$1" out=""
  [[ -e "$dev" ]] || return 1
  out="$( (
    printf 'AT+CIMI\r'
    sleep 0.6
  ) | timeout 3 cat <"$dev" 2>/dev/null | tr -dc '0-9\n' | grep -E '^[0-9]{15}$' | head -1 || true)"
  if [[ -z "$out" ]]; then
    out="$(/usr/sbin/chat -t 4 "" "AT" "OK" "AT+CIMI" "OK" <"$dev" >"$dev" 2>&1 | tr -dc '0-9\n' | grep -E '^[0-9]{15}$' | head -1 || true)"
  fi
  [[ -n "$out" ]] && echo "$out"
}

read_imsi() {
  local out="" d
  if [[ -f "$IMSI_CACHE" ]]; then
    out="$(tr -d ' \n\r' <"$IMSI_CACHE")"
    [[ ${#out} -eq 15 ]] && { echo "$out"; return; }
  fi
  while read -r d; do
    out="$(read_imsi_from_dev "$d" || true)"
    if [[ ${#out} -eq 15 ]]; then
      echo "$out" >"$IMSI_CACHE"
      echo "$out"
      return
    fi
  done < <(modem_candidates)
  echo ""
}

mccmnc_from_imsi() {
  local imsi="$1" code5 code6
  [[ ${#imsi} -ge 5 ]] || { echo ""; return; }
  code5="${imsi:0:5}"
  code6="${imsi:0:6}"
  # Предпочитаем точное совпадение 5 или 6 цифр с профилями
  if [[ -f "$PROFILES" ]]; then
    if grep -q "^${code6}|" "$PROFILES" 2>/dev/null; then
      echo "$code6"
      return
    fi
    if grep -q "^${code5}|" "$PROFILES" 2>/dev/null; then
      echo "$code5"
      return
    fi
  fi
  echo "$code5"
}

build_try_list() {
  local imsi mccmnc op_apns="" last="" generic_apns=""
  imsi="$(read_imsi)"
  mccmnc="$(mccmnc_from_imsi "$imsi")"
  [[ -f "$LAST_FILE" ]] && last="$(tr -d ' \n\r' <"$LAST_FILE")"

  local code name apns
  if [[ -f "$PROFILES" ]]; then
    while IFS='|' read -r code name apns; do
      [[ "$code" == \#* || -z "$code" ]] && continue
      if [[ "$code" == "*" ]]; then
        generic_apns="$apns"
      elif [[ -n "$mccmnc" && "$code" == "$mccmnc" ]]; then
        op_apns="$apns"
        netlog APN_DETECT "Оператор по IMSI" imsi="$imsi" mccmnc="$mccmnc" operator="$name"
      fi
    done <"$PROFILES"
  fi

  # Порядок: last success → APN оператора (и MVNO на том же MNC) → generic из profiles
  local -a list=()
  local a
  for a in "$last" ${op_apns//,/ } ${generic_apns//,/ }; do
    [[ -z "$a" ]] && continue
    local seen=0
    local x
    for x in "${list[@]:-}"; do
      [[ "$x" == "$a" ]] && seen=1 && break
    done
    [[ $seen -eq 0 ]] && list+=("$a")
  done

  # Если profiles недоступен — минимальный fallback
  if [[ ${#list[@]} -eq 0 ]]; then
    list=(internet internet.mts.ru internet.megafon.ru internet.beeline.ru internet.tele2.ru)
  fi

  printf '%s\n' "${list[@]}" >"$LIST_FILE"
  echo 0 >"$IDX_FILE"
  netlog APN_LIST "Собран список APN для перебора" count="${#list[@]}" imsi="${imsi:-unknown}"
  printf '%s\n' "${list[@]}"
}

current_apn() {
  if [[ -f "$CUR_FILE" ]]; then
    tr -d ' \n\r' <"$CUR_FILE"
    return
  fi
  if [[ -f "$LIST_FILE" ]]; then
    head -1 "$LIST_FILE"
    return
  fi
  echo "internet"
}

select_index() {
  local idx="${1:-0}"
  [[ -f "$LIST_FILE" ]] || build_try_list >/dev/null
  local apn
  apn="$(sed -n "$((idx + 1))p" "$LIST_FILE")"
  if [[ -z "$apn" ]]; then
    idx=0
    apn="$(sed -n '1p' "$LIST_FILE")"
  fi
  echo "$idx" >"$IDX_FILE"
  echo "$apn" >"$CUR_FILE"
  netlog APN_SELECT "Выбран APN" apn="$apn" index="$idx"
  echo "$apn"
}

next_apn() {
  [[ -f "$LIST_FILE" ]] || build_try_list >/dev/null
  local idx=0
  [[ -f "$IDX_FILE" ]] && idx="$(cat "$IDX_FILE")"
  idx=$((idx + 1))
  local total
  total="$(wc -l <"$LIST_FILE" | tr -d ' ')"
  if [[ "$idx" -ge "$total" ]]; then
    idx=0
    netlog APN_WRAP "Список APN пройден по кругу" total="$total"
  fi
  select_index "$idx"
}

apply_apn() {
  local apn="${1:-$(current_apn)}"
  local dev=""
  while read -r dev; do
    [[ -e "$dev" ]] || continue
    modprobe usbserial 2>/dev/null || true
    echo "161c f101" > /sys/bus/usb-serial/drivers/generic/new_id 2>/dev/null || true
    if /usr/sbin/chat -V -s -t 8 \
      "" "AT" \
      "OK" "AT+CGDCONT=1,\"IP\",\"${apn}\"" \
      "OK" "AT+CGDCONT=2" \
      "OK" "AT&W" \
      <"$dev" >"$dev"; then
      echo "$apn" >"$CUR_FILE"
      netlog APN_APPLY "APN записан в модем" apn="$apn" modem="$dev"
      return 0
    fi
  done < <(modem_candidates)
  netlog APN_APPLY_FAIL "Не удалось записать APN" apn="$apn" modem="$MODEM"
  return 1
}

mark_success() {
  local apn="${1:-$(current_apn)}"
  local prev=""
  [[ -f "$LAST_FILE" ]] && prev="$(tr -d ' \n\r' <"$LAST_FILE")"
  echo "$apn" >"$LAST_FILE"
  echo "$apn" >"$CUR_FILE"
  if [[ "$prev" != "$apn" ]]; then
    netlog APN_OK "APN подтверждён успехом PPP/LTE" apn="$apn"
  fi
}

# Повторно применить last/current без смены и без пересборки списка
reapply_last() {
  local apn=""
  [[ -f "$LAST_FILE" ]] && apn="$(tr -d ' \n\r' <"$LAST_FILE")"
  [[ -z "$apn" && -f "$CUR_FILE" ]] && apn="$(tr -d ' \n\r' <"$CUR_FILE")"
  if [[ -z "$apn" ]]; then
    build_try_list >/dev/null
    select_index 0 >/dev/null
    apn="$(current_apn)"
  else
    echo "$apn" >"$CUR_FILE"
  fi
  apply_apn "$apn"
  echo "$apn"
}

cmd="${1:-select}"
case "$cmd" in
  select|--select)
    build_try_list >/dev/null
    select_index 0
    ;;
  --next|next)
    next_apn
    ;;
  --apply|apply)
    apn="$(current_apn)"
    [[ -f "$LIST_FILE" ]] || build_try_list >/dev/null
    [[ -f "$CUR_FILE" ]] || select_index 0 >/dev/null
    apn="$(current_apn)"
    apply_apn "$apn"
    echo "$apn"
    ;;
  --reapply-last|reapply-last)
    reapply_last
    ;;
  --success|success)
    mark_success "$(current_apn)"
    ;;
  --show|show)
    echo "current=$(current_apn)"
    echo "last=$(cat "$LAST_FILE" 2>/dev/null || true)"
    echo "list:"
    cat "$LIST_FILE" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 {select|next|apply|reapply-last|success|show}" >&2
    exit 2
    ;;
esac
