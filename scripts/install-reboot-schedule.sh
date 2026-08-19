#!/usr/bin/env bash
# Установить/снять плановую перезагрузку по config.env
# Переменные:
#   REBOOT_SCHEDULE_KIND=daily|weekly|monthly|  (пусто = выкл)
#   REBOOT_SCHEDULE_TIME=HH:MM
#   REBOOT_SCHEDULE_DAY=  weekly: Sun..Sat|0-6; monthly: 1-28
#   REBOOT_SCHEDULE_ONCALENDAR=  если задан — приоритет над KIND
set -euo pipefail

: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
# shellcheck disable=SC1091
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh" 2>/dev/null || true

UNIT_SVC=systema-scheduled-reboot.service
UNIT_TMR=systema-scheduled-reboot.timer
SVC_PATH=/etc/systemd/system/$UNIT_SVC
TMR_PATH=/etc/systemd/system/$UNIT_TMR

if [[ "$(id -u)" -ne 0 ]]; then
  echo "нужен root" >&2
  exit 1
fi

disable_schedule() {
  systemctl disable --now "$UNIT_TMR" 2>/dev/null || true
  rm -f "$SVC_PATH" "$TMR_PATH"
  systemctl daemon-reload
  echo "scheduled reboot: disabled"
}

KIND="${REBOOT_SCHEDULE_KIND:-}"
TIME="${REBOOT_SCHEDULE_TIME:-04:00}"
DAY="${REBOOT_SCHEDULE_DAY:-Sun}"
ONCAL="${REBOOT_SCHEDULE_ONCALENDAR:-}"

if [[ -z "$KIND" && -z "$ONCAL" ]]; then
  disable_schedule
  exit 0
fi

# HH:MM → HH:MM:00
if [[ ! "$TIME" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
  echo "REBOOT_SCHEDULE_TIME must be HH:MM, got: $TIME" >&2
  exit 2
fi
HOUR="${TIME%%:*}"
MIN="${TIME##*:}"
HOUR=$((10#$HOUR))
MIN=$((10#$MIN))
printf -v TIMESPEC "%02d:%02d:00" "$HOUR" "$MIN"

weekday_to_cal() {
  local d="${1,,}"
  case "$d" in
    0|sun|sunday) echo Sun ;;
    1|mon|monday) echo Mon ;;
    2|tue|tuesday) echo Tue ;;
    3|wed|wednesday) echo Wed ;;
    4|thu|thursday) echo Thu ;;
    5|fri|friday) echo Fri ;;
    6|sat|saturday) echo Sat ;;
    *) echo "" ;;
  esac
}

if [[ -z "$ONCAL" ]]; then
  case "$KIND" in
    daily)
      ONCAL="*-*-* ${TIMESPEC}"
      ;;
    weekly)
      w="$(weekday_to_cal "$DAY")"
      if [[ -z "$w" ]]; then
        echo "REBOOT_SCHEDULE_DAY invalid for weekly: $DAY (Sun..Sat or 0-6)" >&2
        exit 2
      fi
      ONCAL="${w} *-*-* ${TIMESPEC}"
      ;;
    monthly)
      if [[ ! "$DAY" =~ ^([1-9]|[12][0-9]|3[01])$ ]]; then
        echo "REBOOT_SCHEDULE_DAY for monthly must be 1-31, got: $DAY" >&2
        exit 2
      fi
      printf -v dom "%02d" "$DAY"
      ONCAL="*-*-${dom} ${TIMESPEC}"
      ;;
    *)
      echo "REBOOT_SCHEDULE_KIND must be daily|weekly|monthly (or set ONCALENDAR), got: $KIND" >&2
      exit 2
      ;;
  esac
fi

cat >"$SVC_PATH" <<EOF
[Unit]
Description=systema-router scheduled reboot
Documentation=file:$SYSTEMA_ROUTER_ROOT/docs/INSTALL.md

[Service]
Type=oneshot
Environment=SYSTEMA_ROUTER_ROOT=$SYSTEMA_ROUTER_ROOT
ExecStart=$SYSTEMA_ROUTER_ROOT/scripts/scheduled-reboot.sh
EOF

cat >"$TMR_PATH" <<EOF
[Unit]
Description=systema-router scheduled reboot timer
Documentation=file:$SYSTEMA_ROUTER_ROOT/docs/INSTALL.md

[Timer]
OnCalendar=$ONCAL
Persistent=true
Unit=$UNIT_SVC

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "$UNIT_TMR"
echo "scheduled reboot: OnCalendar=$ONCAL"
systemctl list-timers "$UNIT_TMR" --no-pager 2>/dev/null || systemctl status "$UNIT_TMR" --no-pager -l | head -15
