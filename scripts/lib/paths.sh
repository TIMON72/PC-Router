#!/usr/bin/env bash
# Пути проекта. Корень: PC_ROUTER_ROOT или SYSTEMA_ROUTER_ROOT (совместимость).
# shellcheck shell=bash
: "${SYSTEMA_ROUTER_ROOT:=${PC_ROUTER_ROOT:-/home/admin/PC-Router}}"
: "${CONFIG_FILE:=$SYSTEMA_ROUTER_ROOT/config.env}"
: "${APN_PROFILES_FILE:=$SYSTEMA_ROUTER_ROOT/conf/apn-profiles.conf}"
: "${APN_LAST_FILE:=$SYSTEMA_ROUTER_ROOT/state/apn.last}"
: "${NETLOG_DIR:=$SYSTEMA_ROUTER_ROOT}"
: "${NETLOG_FILE:=$NETLOG_DIR/logs.log}"
: "${LOG_FILE:=$NETLOG_DIR/lte-failover.log}"
: "${REBOOT_STATE_DIR:=$SYSTEMA_ROUTER_ROOT/state}"
: "${NETLOG_STATE_DIR:=/run/systema-router}"
: "${LTE_APN_SELECT:=$SYSTEMA_ROUTER_ROOT/scripts/lte-apn-select.sh}"

export SYSTEMA_ROUTER_ROOT CONFIG_FILE APN_PROFILES_FILE APN_LAST_FILE
export NETLOG_DIR NETLOG_FILE LOG_FILE REBOOT_STATE_DIR NETLOG_STATE_DIR LTE_APN_SELECT

mkdir -p "$SYSTEMA_ROUTER_ROOT/state" "$SYSTEMA_ROUTER_ROOT/conf" \
  "$NETLOG_DIR" "$NETLOG_STATE_DIR" 2>/dev/null || true
