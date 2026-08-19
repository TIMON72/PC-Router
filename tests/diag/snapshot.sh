#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
snap "${1:-DIAG}"
echo "-- outage.state --"
cat /home/admin/PC-Router/state/outage.state 2>/dev/null || echo "(none)"
echo "-- softfail --"
cat /run/systema-router/lte.softfail 2>/dev/null || echo "0"
echo "-- test.env --"
[[ -f "$TEST_ENV_FILE" ]] && cat "$TEST_ENV_FILE" || echo "(inactive)"
echo "-- recent log --"
log_tail 25
