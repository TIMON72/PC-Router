#!/usr/bin/env bash
# shellcheck shell=bash
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_LIB/paths.sh"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
: "${APN_PROFILES_FILE:=$SYSTEMA_ROUTER_ROOT/conf/apn-profiles.conf}"
: "${APN_LAST_FILE:=$SYSTEMA_ROUTER_ROOT/state/apn.last}"
: "${NETLOG_DIR:=$SYSTEMA_ROUTER_ROOT}"
: "${NETLOG_FILE:=$NETLOG_DIR/logs.log}"
: "${LOG_FILE:=$NETLOG_DIR/lte-failover.log}"
: "${REBOOT_STATE_DIR:=$SYSTEMA_ROUTER_ROOT/state}"
: "${LTE_APN_SELECT:=$SYSTEMA_ROUTER_ROOT/scripts/lte-apn-select.sh}"
# DEVICE_* — предпочтительные имена; CAMERA_* — совместимость со старыми площадками
if [[ -z "${DEVICE_LEASES:-}" && -n "${CAMERA_LEASES:-}" ]]; then
  DEVICE_LEASES="$CAMERA_LEASES"
fi
if [[ -z "${DEVICE_FORWARDS:-}" && -n "${CAMERA_FORWARDS:-}" ]]; then
  DEVICE_FORWARDS="$CAMERA_FORWARDS"
fi
CAMERA_LEASES="${DEVICE_LEASES:-}"
CAMERA_FORWARDS="${DEVICE_FORWARDS:-}"
export DEVICE_LEASES DEVICE_FORWARDS CAMERA_LEASES CAMERA_FORWARDS
# shellcheck disable=SC1091
source "$_LIB/netlog.sh" 2>/dev/null || true
