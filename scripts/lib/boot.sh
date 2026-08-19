#!/usr/bin/env bash
# Общий префикс для скриптов в $SYSTEMA_ROUTER_ROOT/scripts/
# shellcheck shell=bash
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
# shellcheck disable=SC1091
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh"
type netlog >/dev/null 2>&1 || netlog() { :; }
