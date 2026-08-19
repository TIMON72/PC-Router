#!/usr/bin/env bash
# Failsafe: мягкое восстановление + эскалация reboot при длительном outage
set -u
# shellcheck disable=SC1091
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh"
type netlog >/dev/null 2>&1 || netlog() { :; }
# shellcheck disable=SC1091

WAN_IF="${WAN_IF:-enp3s0}"
LTE_IF="${LTE_IF:-ppp0}"
PING_HOST="${PING_HOST:-8.8.8.8}"
PING_HOST_ALT="${PING_HOST_ALT:-1.1.1.1}"
OPENVPN_UNIT="${OPENVPN_UNIT:-openvpn@vpn.service}"
LTE_UNIT="${LTE_UNIT:-lte.service}"
EDGE_MODE="${EDGE_MODE:-vpn}"
FAILSAFE_NEED="${FAILSAFE_NEED:-2}"
REBOOT_ON_OUTAGE="${REBOOT_ON_OUTAGE:-1}"
# 1ч, 2ч, 4ч, 6ч, 12ч, далее каждые 24ч
REBOOT_SCHEDULE_SEC="${REBOOT_SCHEDULE_SEC:-3600,7200,14400,21600,43200,86400}"
# Тесты: не делать реальный reboot, только лог REBOOT_DRY
REBOOT_DRY_RUN="${REBOOT_DRY_RUN:-0}"
# Опциональные оверрайды для ускоренных сценариев (tests/)
# shellcheck disable=SC1091
[[ -f /run/systema-router/test.env ]] && source /run/systema-router/test.env

ST="${NETLOG_STATE_DIR:-/run/systema-router}/failsafe.count"
PERSIST_DIR="${REBOOT_STATE_DIR:-$SYSTEMA_ROUTER_ROOT/state}"
OUTAGE_FILE="$PERSIST_DIR/outage.state"

netlog_init
mkdir -p "$(dirname "$ST")" "$PERSIST_DIR"

now=$(date +%s)

# --- helpers: persistent outage/reboot state ---
outage_load() {
  level=0
  wait_started=0
  last_reboot=0
  outage_since=0
  # shellcheck disable=SC1090
  [[ -f "$OUTAGE_FILE" ]] && source "$OUTAGE_FILE" || true
  level="${level:-0}"
  wait_started="${wait_started:-0}"
  last_reboot="${last_reboot:-0}"
  outage_since="${outage_since:-0}"
}

outage_save() {
  cat >"$OUTAGE_FILE" <<EOF
level=$level
wait_started=$wait_started
last_reboot=$last_reboot
outage_since=$outage_since
EOF
}

outage_clear() {
  level=0
  wait_started=0
  outage_since=0
  outage_save
}

schedule_wait_sec() {
  local idx="$1" IFS=',' arr n
  read -r -a arr <<<"$REBOOT_SCHEDULE_SEC"
  n="${#arr[@]}"
  [[ "$n" -lt 1 ]] && { echo 86400; return; }
  if [[ "$idx" -ge "$n" ]]; then
    echo "${arr[$((n - 1))]}"
  else
    echo "${arr[$idx]}"
  fi
}

internet_ok() {
  ping -c 1 -W 2 "$PING_HOST" >/dev/null 2>&1 && return 0
  [[ -n "$PING_HOST_ALT" ]] && ping -c 1 -W 2 "$PING_HOST_ALT" >/dev/null 2>&1 && return 0
  return 1
}

# Снимаем только протухший hold (>3 мин)
if [[ -f /tmp/hold-wan-down ]]; then
  age=$((now - $(stat -c %Y /tmp/hold-wan-down 2>/dev/null || echo "$now")))
  if [[ "$age" -gt 180 ]]; then
    rm -f /tmp/hold-wan-down
    pkill -f 'hold-wan-down' 2>/dev/null || true
    netlog FAILSAFE "Удалён протухший hold-wan-down" age_sec="$age"
  fi
fi

outage_load

if internet_ok; then
  echo 0 >"$ST"
  if [[ "${outage_since:-0}" -gt 0 || "${level:-0}" -gt 0 ]]; then
    netlog OUTAGE_CLEAR "Интернет восстановлен" was_level="$level" outage_sec="$((now - outage_since))"
  fi
  outage_clear
  exit 0
fi

# --- нет интернета ---
count=0
[[ -f "$ST" ]] && count="$(cat "$ST" 2>/dev/null || echo 0)"
count=$((count + 1))
echo "$count" >"$ST"
netlog FAILSAFE_PROBE "Нет default-интернета" count="$count" need="$FAILSAFE_NEED"

if [[ "$outage_since" -eq 0 ]]; then
  outage_since=$now
  wait_started=$now
  outage_save
  netlog OUTAGE_START "Начало эпизода без интернета" level="$level"
fi
if [[ "$wait_started" -eq 0 ]]; then
  wait_started=$now
  outage_save
fi

if [[ "$count" -ge "$FAILSAFE_NEED" ]]; then
  # Не ломаем активный короткий тест
  if [[ ! -f /tmp/hold-wan-down ]]; then
    netlog FAILSAFE_ACTION "Восстановление uplink" wan="$WAN_IF" lte="$LTE_IF"
    ip link set "$WAN_IF" up 2>/dev/null || true
    networkctl up "$WAN_IF" 2>/dev/null || true
    systemctl start "$LTE_UNIT" 2>/dev/null || true
    sleep 5

    if ip -4 addr show "$WAN_IF" 2>/dev/null | grep -q inet; then
      gw="$(ip -4 route show dev "$WAN_IF" | awk '/default/{print $3; exit}')"
      [[ -z "$gw" ]] && gw="$(ip -4 -o addr show "$WAN_IF" | awk '{print $4}' | cut -d/ -f1 | head -1 | awk -F. '{print $1"."$2"."$3".1"}')"
      [[ -n "$gw" ]] && ip route replace default via "$gw" dev "$WAN_IF" metric 100
    fi
    if ip -4 addr show "$LTE_IF" 2>/dev/null | grep -q inet; then
      ip route replace default dev "$LTE_IF" metric 500 2>/dev/null || true
    fi

    if [[ "${EDGE_MODE:-vpn}" == "vpn" ]]; then
      systemctl restart "$OPENVPN_UNIT" 2>/dev/null || true
    fi
    # Не рестартим lte-failover — иначе сбиваем его cooldown/APN-логику и гоняем LTE
    systemctl start lte-failover.service 2>/dev/null || true
  fi
  echo 0 >"$ST"
fi

# --- эскалация reboot ---
if [[ "$REBOOT_ON_OUTAGE" != "1" ]]; then
  exit 0
fi
if [[ -f /tmp/hold-wan-down ]]; then
  exit 0
fi

need_sec="$(schedule_wait_sec "$level")"
elapsed=$((now - wait_started))
# Не спамить: лог раз в ~15 мин или когда близко к reboot
if [[ $((elapsed % 900)) -lt 70 ]] || [[ $((need_sec - elapsed)) -le 120 ]]; then
  netlog OUTAGE_WAIT "Ожидание до reboot" level="$level" need_sec="$need_sec" elapsed_sec="$elapsed" outage_sec="$((now - outage_since))"
fi

if [[ "$elapsed" -lt "$need_sec" ]]; then
  exit 0
fi

# Пора перезагружаться
next_level=$((level + 1))
last_reboot=$now
wait_started=$now
old_level=$level
level=$next_level
outage_save
sync

if [[ "$REBOOT_DRY_RUN" == "1" ]]; then
  netlog REBOOT_DRY "Тест: reboot НЕ выполнен (DRY_RUN)" \
    level="$old_level" next_level="$level" waited_sec="$elapsed" outage_sec="$((now - outage_since))"
  logger -t systema-router -p local0.warning -- "REBOOT_DRY level=$old_level waited=${elapsed}s"
  exit 0
fi

netlog REBOOT "Перезагрузка из-за длительного outage" \
  level="$old_level" next_level="$level" waited_sec="$elapsed" outage_sec="$((now - outage_since))"
logger -t systema-router -p local0.err -- "REBOOT due to outage level=$old_level waited=${elapsed}s"

# Небольшая пауза, чтобы лог успел сброситься на диск
sleep 2
sync
/sbin/reboot || systemctl reboot
exit 0
