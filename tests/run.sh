#!/usr/bin/env bash
# Единая точка входа: sudo bash tests/run.sh <cmd> [args...]
set -u
TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: sudo bash tests/run.sh <command> [args...]

Commands:
  list                 — список сценариев
  snap [label]         — диагностика (snapshot)
  events [N] [filter]  — хвост журнала
  wan-failover [deadline] [dwell]
  lte-soft-fail [observe_sec]
  outage-dry [max_wait_sec]
  help
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  list)
    usage
    echo
    echo "scenarios:"
    ls -1 "$TESTS_ROOT/scenarios"/*.sh 2>/dev/null | xargs -n1 basename
    ;;
  snap|snapshot)
    bash "$TESTS_ROOT/diag/snapshot.sh" "$@"
    ;;
  events|log)
    bash "$TESTS_ROOT/diag/recent-events.sh" "$@"
    ;;
  wan-failover|wan)
    bash "$TESTS_ROOT/scenarios/wan-failover.sh" "$@"
    ;;
  lte-soft-fail|lte-soft)
    bash "$TESTS_ROOT/scenarios/lte-soft-fail.sh" "$@"
    ;;
  outage-dry|outage)
    bash "$TESTS_ROOT/scenarios/outage-escalation.sh" "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
