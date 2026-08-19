#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
N="${1:-60}"
FILTER="${2:-WAN_|LTE_|VPN_|APN_|OUTAGE_|REBOOT|FAILSAFE|TEST_|NO_UPLINK}"
echo "=== last $N matching /$FILTER/ in $NETLOG_FILE ==="
grep -E "$FILTER" "$NETLOG_FILE" 2>/dev/null | tail -n "$N" || echo "(no matches)"
