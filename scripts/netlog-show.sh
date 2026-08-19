#!/usr/bin/env bash
# Показать журнал подключений
#   netlog-show.sh [file] [lines]
#   netlog-show.sh 100
set -u
# shellcheck disable=SC1091
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh"
type netlog >/dev/null 2>&1 || netlog() { :; }
FILE="${NETLOG_FILE:-/home/admin/PC-Router/logs.log}"
LINES=80
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  LINES="$1"
elif [[ -n "${1:-}" ]]; then
  FILE="$1"
  [[ "${2:-}" =~ ^[0-9]+$ ]] && LINES="$2"
fi
if [[ ! -f "$FILE" ]]; then
  echo "Нет лога: $FILE" >&2
  exit 1
fi
echo "=== last $LINES of $FILE ==="
tail -n "$LINES" "$FILE"
echo
echo "=== summary (event counts) ==="
awk -F'|' 'NF>=2{c[$2]++} END{for (k in c) printf "%6d  %s\n", c[k], k}' "$FILE" | sort -rn
