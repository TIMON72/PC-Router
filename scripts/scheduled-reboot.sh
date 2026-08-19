#!/usr/bin/env bash
# Вызывается systemd timer'ом плановой перезагрузки
set -u
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
# shellcheck disable=SC1091
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh" 2>/dev/null || true
type netlog >/dev/null 2>&1 || netlog() { logger -t systema-router -- "$*"; }

netlog REBOOT_SCHEDULED "Плановая перезагрузка" \
  kind="${REBOOT_SCHEDULE_KIND:-}" \
  time="${REBOOT_SCHEDULE_TIME:-}" \
  day="${REBOOT_SCHEDULE_DAY:-}" \
  oncalendar="${REBOOT_SCHEDULE_ONCALENDAR:-}"
logger -t systema-router -p local0.warning -- "REBOOT_SCHEDULED"
sync
sleep 2
sync
/sbin/reboot || systemctl reboot
