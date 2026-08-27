#!/usr/bin/env bash
# Хвост persistent boot timeline (state/boot-timeline.log)
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
N="${1:-40}"
FILE="${REBOOT_STATE_DIR:-$SYSTEMA_ROUTER_ROOT/state}/boot-timeline.log"
echo "=== boot-timeline last $N ($FILE) ==="
if [[ -f "$FILE" ]]; then
  tail -n "$N" "$FILE"
else
  echo "(none)"
fi
