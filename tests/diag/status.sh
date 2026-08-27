#!/usr/bin/env bash
# Сервисная диагностика площадки: интерфейсы, сервисы, события за N дней.
# Usage: status.sh [days]
#   days — окно отчёта (по умолчанию 1)
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_root "$@"

DAYS="${1:-1}"
[[ "$DAYS" =~ ^[0-9]+$ ]] || DAYS=1
OUTAGE_FILE="${REBOOT_STATE_DIR:-$SYSTEMA_ROUTER_ROOT/state}/outage.state"
TIMELINE="${REBOOT_STATE_DIR:-$SYSTEMA_ROUTER_ROOT/state}/boot-timeline.log"
LEASE_FILE="${DHCP_LEASEFILE:-/var/lib/misc/dnsmasq.leases}"
LAN_ADDR="${LAN_ADDR:-192.168.50.1}"
now="$(date +%s)"
cutoff_epoch=$((now - DAYS * 86400))
cutoff="$(date -d "@${cutoff_epoch}" -Iseconds 2>/dev/null || date -d "${DAYS} days ago" -Iseconds 2>/dev/null || echo "")"

_fmt_epoch() {
  date -d "@$1" '+%d.%m.%Y %H:%M' 2>/dev/null || echo "@$1"
}

_human_dur() {
  local s="$1" d h m
  (( s < 60 )) && { echo "${s}с"; return; }
  m=$((s / 60))
  (( m < 60 )) && { echo "${m}мин"; return; }
  h=$((m / 60))
  m=$((m % 60))
  (( h < 48 )) && { echo "${h}ч ${m}мин"; return; }
  d=$((h / 24))
  h=$((h % 24))
  echo "${d}д ${h}ч"
}

_uplink_label() {
  case "${1:-unknown}" in
    wan) echo "WAN" ;;
    lte) echo "LTE" ;;
    *) echo "${1:-?}" ;;
  esac
}

_active_path() {
  grep -E '^path=' /run/lte-failover.state 2>/dev/null | cut -d= -f2- || echo unknown
}

# Счётчики и последние события из netlog за окно (один проход awk).
to_wan=0 to_lte=0 wan_down=0 lte_down=0 vpn_restart=0 usb_reseat=0
reboot_ev=0
if [[ -f "$NETLOG_FILE" && -n "$cutoff" ]]; then
  # shellcheck disable=SC2034
  eval "$(
    awk -v cut="$cutoff" -F'|' '
      NF >= 2 && $1 >= cut {
        if ($2 == "PATH_SWITCH" && $0 ~ /to=wan/) tw++
        if ($2 == "PATH_SWITCH" && $0 ~ /to=lte/) tl2++
        if ($2 == "WAN_DOWN") wd++
        if ($2 == "LTE_DOWN") ld++
        if ($2 == "VPN_RESTART") vr++
        if ($2 == "USB_RESEAT") ur++
        if ($2 ~ /^REBOOT/) rb++
      }
      END {
        printf "to_wan=%d\nto_lte=%d\nwan_down=%d\nlte_down=%d\nvpn_restart=%d\nusb_reseat=%d\nreboot_ev=%d\n",
          tw + 0, tl2 + 0, wd + 0, ld + 0, vr + 0, ur + 0, rb + 0
      }
    ' "$NETLOG_FILE"
  )"
fi

echo "========== PC-Router STATUS $(ts) =========="
echo "host=$(hostname)  режим=${EDGE_MODE}  окно=${DAYS} д."
echo

# --- live snapshot ---
echo "=== Сейчас ==="
uptime -p 2>/dev/null || uptime
path="$(_active_path)"
echo "Активный uplink: $(_uplink_label "$path")"
echo

printf '%-8s %-10s %-8s %-18s %s\n' "IFACE" "ROLE" "LINK" "IPv4" "PING"
_iface_row() {
  local ifc="$1" role="$2"
  local link="-" ip4="-" ping="-"
  if [[ -d "/sys/class/net/${ifc}" ]]; then
    link="$(cat "/sys/class/net/${ifc}/operstate" 2>/dev/null || echo ?)"
    local car
    car="$(cat "/sys/class/net/${ifc}/carrier" 2>/dev/null || echo ?)"
    [[ "$car" == "1" ]] && link="${link}/carrier"
    ip4="$(ip -4 -o addr show "$ifc" 2>/dev/null | awk '{print $4; exit}')"
    [[ -z "$ip4" ]] && ip4="-"
    if [[ "$role" == "LAN" ]]; then
      ping="n/a"
    elif ping -I "$ifc" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
      ping="OK"
    else
      ping="FAIL"
    fi
  else
    link="missing"
  fi
  printf '%-8s %-10s %-8s %-18s %s\n' "$ifc" "$role" "$link" "$ip4" "$ping"
}
_iface_row "$WAN_IF" "WAN"
_iface_row "$LTE_IF" "LTE"
_iface_row "$LAN_IF" "LAN"
_iface_row "$VPN_IF" "VPN"
echo "-- default route --"
ip route show default 2>/dev/null || echo "(none)"
echo

# --- period summary ---
echo "=== За последние ${DAYS} д. ==="

boots_in_window=0
if command -v journalctl >/dev/null 2>&1; then
  while read -r idx _bid dow d t tz dow2 d2 t2 tz2 _rest; do
    [[ "$idx" =~ ^-?[0-9]+$ ]] || continue
    start_e=$(date -d "$d $t $tz" +%s 2>/dev/null) || continue
    if [[ -n "${d2:-}" && -n "${t2:-}" ]]; then
      end_e=$(date -d "$d2 $t2 $tz2" +%s 2>/dev/null) || end_e=$now
    else
      end_e=$now
    fi
    (( end_e < cutoff_epoch )) && continue
    boots_in_window=$((boots_in_window + 1))
    start_h="$(_fmt_epoch "$start_e")"
    if [[ "$idx" == "0" && start_e -lt cutoff_epoch ]]; then
      echo "Перезагрузок в окне: нет (текущая сессия с $start_h, $(_human_dur $((now - start_e))))"
      boots_in_window=-1
      break
    fi
    if [[ "$idx" == "0" ]]; then
      prev=$((boots_in_window - 1))
      if (( prev == 0 )); then
        echo "Перезагрузок в окне: 1 (текущая сессия с $start_h, $(_human_dur $((now - start_e))))"
      else
        echo "Перезагрузок в окне: ${prev} + текущая (с $start_h, $(_human_dur $((now - start_e))))"
      fi
      boots_in_window=-1
      break
    fi
  done < <(journalctl --list-boots 2>/dev/null | tail -n 40)
fi
if (( boots_in_window == 0 )); then
  echo "Перезагрузок в окне: нет"
elif (( boots_in_window > 0 )); then
  echo "Перезагрузок в окне: ${boots_in_window} (см. journal на устройстве)"
fi

switch_total=$((to_wan + to_lte))
if (( switch_total == 0 )); then
  echo "Переключений uplink: не было"
else
  echo "Переключений uplink: ${switch_total} (→ WAN: ${to_wan}, → LTE: ${to_lte})"
fi

ev_parts=()
(( wan_down > 0 )) && ev_parts+=("WAN down ×${wan_down}")
(( lte_down > 0 )) && ev_parts+=("LTE down ×${lte_down}")
(( vpn_restart > 0 )) && ev_parts+=("VPN restart ×${vpn_restart}")
(( usb_reseat > 0 )) && ev_parts+=("USB reseat ×${usb_reseat}")
(( reboot_ev > 0 )) && ev_parts+=("reboot ×${reboot_ev}")
if ((${#ev_parts[@]} == 0)); then
  echo "События: без заметных проблем"
else
  echo "События: $(IFS=', '; echo "${ev_parts[*]}")"
fi

level=0 wait_started=0 last_reboot=0 outage_since=0
# shellcheck disable=SC1090
[[ -f "$OUTAGE_FILE" ]] && source "$OUTAGE_FILE" || true
level="${level:-0}"
wait_started="${wait_started:-0}"
last_reboot="${last_reboot:-0}"
outage_since="${outage_since:-0}"
if (( level > 0 || outage_since > 0 )); then
  if (( outage_since >= cutoff_epoch )); then
    echo "Outage-эскалация: уровень ${level}, простой с $(_fmt_epoch "$outage_since")"
    if (( wait_started > 0 && level > 0 )); then
      echo "  ожидание до reboot: $(_human_dur $((now - wait_started))) (с $(_fmt_epoch "$wait_started")))"
    fi
  elif (( last_reboot >= cutoff_epoch )); then
    echo "Outage-reboot: $(_fmt_epoch "$last_reboot")"
  fi
elif (( reboot_ev == 0 && boots_in_window <= 0 )); then
  echo "Outage-reboot: не было"
fi
echo

_openvpn_enable_label() {
  local en base profile autostart
  en="$(systemctl is-enabled "$OPENVPN_UNIT" 2>/dev/null || echo unknown)"
  [[ "$en" == "enabled" ]] && { echo "enabled"; return; }
  base="$(systemctl is-enabled openvpn.service 2>/dev/null || echo -)"
  profile="${OPENVPN_UNIT#*@}"
  profile="${profile%.service}"
  autostart="$(grep -E '^AUTOSTART=' /etc/default/openvpn 2>/dev/null | sed -n 's/^AUTOSTART=//p' | tr -d '\"' || true)"
  if [[ "$en" == "enabled-runtime" && "$base" == "enabled" ]]; then
    if [[ "$autostart" == "all" || "$autostart" == "$profile" || " $autostart " == *" $profile "* ]]; then
      echo "enabled (openvpn.service + AUTOSTART)"
      return
    fi
  fi
  echo "$en"
}

# --- services ---
echo "=== services ==="
_svc() {
  local u="$1"
  local st
  st="$(systemctl is-active "$u" 2>/dev/null || echo missing)"
  local en
  en="$(systemctl is-enabled "$u" 2>/dev/null || echo -)"
  printf '  %-28s %-10s enabled=%s\n' "$u" "$st" "$en"
}
_svc dnsmasq.service
_svc "$LTE_UNIT"
_svc lte-failover.service
_svc network-failsafe.timer
if [[ "$EDGE_MODE" == "vpn" ]]; then
  st="$(systemctl is-active "$OPENVPN_UNIT" 2>/dev/null || echo missing)"
  printf '  %-28s %-10s enabled=%s\n' "$OPENVPN_UNIT" "$st" "$(_openvpn_enable_label)"
fi
echo

# --- DHCP / LAN clients ---
echo "=== DHCP / LAN clients ==="
leases_active=0
if systemctl is-active --quiet dnsmasq; then
  echo "dnsmasq: active  LAN_ADDR=${LAN_ADDR}"
else
  echo "dnsmasq: $(systemctl is-active dnsmasq 2>/dev/null || echo unknown)"
fi
if [[ -f "$LEASE_FILE" ]]; then
  while read -r exp mac ip host _rest; do
    [[ -z "${exp:-}" || ! "$exp" =~ ^[0-9]+$ ]] && continue
    if (( exp == 0 || exp > now )); then
      leases_active=$((leases_active + 1))
      echo "  lease  ${ip:-?}  ${mac:-?}  ${host:-*}"
    fi
  done <"$LEASE_FILE"
fi
echo "active_leases=${leases_active}"
neigh_n=0
while read -r _ip rest; do
  [[ -z "${_ip:-}" ]] && continue
  if echo "$rest" | grep -Eq 'REACHABLE|STALE|DELAY|PROBE|PERMANENT'; then
    neigh_n=$((neigh_n + 1))
  fi
done < <(ip -4 neigh show dev "$LAN_IF" 2>/dev/null || true)
echo "neigh_seen=${neigh_n}"
echo

# --- APN ---
echo "=== APN ==="
"$SYSTEMA_ROUTER_ROOT/scripts/lte-apn-select.sh" show 2>/dev/null | head -8 || echo "(n/a)"
echo

# --- problems (only if any in window) ---
if [[ -f "$NETLOG_FILE" && -n "$cutoff" ]]; then
  problems="$(
    awk -v cut="$cutoff" -F'|' '
      NF >= 2 && $1 >= cut && $2 ~ /(DOWN|FAIL|OUTAGE|NO_UPLINK|REBOOT|RESTART_FAIL|USB_RESEAT)/ {
        split($1, dt, "T")
        sub(/\+.*/, "", dt[2])
        msg = $3
        gsub(/\|.*/, "", msg)
        printf "  %s %s  %s\n", substr(dt[1], 6), substr(dt[2], 1, 5), msg
      }
    ' "$NETLOG_FILE" | tail -n 20
  )"
  if [[ -n "$problems" ]]; then
    echo "=== Проблемы за ${DAYS} д. ==="
    echo "$problems"
    echo
  fi
fi

# --- path switches (only if any) ---
if (( switch_total > 0 )) && [[ -f "$NETLOG_FILE" && -n "$cutoff" ]]; then
  echo "=== Переключения uplink ==="
  awk -v cut="$cutoff" -F'|' '
    NF >= 2 && $1 >= cut && $2 == "PATH_SWITCH" {
      split($1, dt, "T")
      sub(/\+.*/, "", dt[2])
      dir = "?"; if ($0 ~ /to=wan/) dir = "WAN"; else if ($0 ~ /to=lte/) dir = "LTE"
      printf "  %s %s  → %s\n", substr(dt[1], 6), substr(dt[2], 1, 5), dir
    }
  ' "$NETLOG_FILE" | tail -n 25
  echo
fi

# --- boot timeline (filtered) ---
if [[ -f "$TIMELINE" && -n "$cutoff" ]]; then
  timeline_filtered="$(
    awk -v cut="$cutoff" -F'|' '
      NF >= 2 && $1 >= cut && $2 ~ /^(PATH_SWITCH|WAN_DOWN|WAN_UP|LTE_DOWN|LTE_UP|VPN_RESTART|VPN_DOWN|VPN_UP|REBOOT|REBOOT_DRY|REBOOT_SCHEDULED|OUTAGE|USB_RESEAT|NO_UPLINK)/ {
        split($1, dt, "T")
        sub(/\+.*/, "", dt[2])
        msg = $3
        gsub(/\|.*/, "", msg)
        printf "  %s %s  %s\n", substr(dt[1], 6), substr(dt[2], 1, 5), msg
      }
    ' "$TIMELINE" | tail -n 20
  )"
  if [[ -n "$timeline_filtered" ]]; then
    echo "=== Хронология за ${DAYS} д. ==="
    echo "$timeline_filtered"
    echo
  fi
fi

# --- resources ---
echo "=== resources ==="
df -h / 2>/dev/null | head -n 2
free -h 2>/dev/null | head -n 2 || true
echo

# --- warnings only ---
warnings=()
systemctl is-active --quiet dnsmasq || warnings+=("dnsmasq не active — LAN DHCP может не работать")
ip -4 addr show "$LAN_IF" 2>/dev/null | grep -q "inet ${LAN_ADDR}/" \
  || warnings+=("нет ${LAN_ADDR} на ${LAN_IF}")
if [[ ! -d "/sys/class/net/${WAN_IF}" ]] \
  || [[ "$(cat "/sys/class/net/${WAN_IF}/carrier" 2>/dev/null || echo 0)" != "1" ]]; then
  warnings+=("WAN (${WAN_IF}) без carrier / отсутствует")
fi
if ! iface_exists "$LTE_IF" && ! compgen -G '/dev/ttyUSB*' >/dev/null 2>&1; then
  warnings+=("LTE: нет ${LTE_IF} и USB-модема")
fi
if [[ "$EDGE_MODE" == "vpn" ]] && ! ip -4 addr show "$VPN_IF" 2>/dev/null | grep -q inet; then
  warnings+=("VPN (${VPN_IF}) без IPv4")
fi
if ((${#warnings[@]} > 0)); then
  echo "=== Внимание ==="
  for w in "${warnings[@]}"; do
    echo "  ! $w"
  done
  echo
fi

echo "========== end status =========="
