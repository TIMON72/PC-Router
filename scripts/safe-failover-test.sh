#!/usr/bin/env bash
# Совместимая обёртка → tests/scenarios/wan-failover.sh
set -u
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
exec bash "$SYSTEMA_ROUTER_ROOT/tests/scenarios/wan-failover.sh" "$@"
