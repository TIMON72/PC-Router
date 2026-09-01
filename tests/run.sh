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
  status [days]        — сервисный отчёт (интерфейсы, обрывы за N дней; по умолчанию 1)
  dhcp|dhcp-lan        — dnsmasq жив + число LAN-клиентов
  events [N] [filter]  — хвост журнала
  boot-timeline [N]    — хвост state/boot-timeline.log
  recover-selftest     — unit-check lib recovery (без железа)
  sysctl-panic         — lockup→panic→reboot sysctl (без crash)
  panic-reboot [observe]— sysrq panic→reboot (suite: WAN|LTE)
  wan-failover [deadline] [dwell]
  vpn-lte-boot [deadline]
  reboot-wan [observe] — реальный reboot, только WAN (+VPN)
  reboot-lte [observe]  — реальный reboot, только LTE (+VPN)
  reboot-both [observe]— реальный reboot, WAN+LTE (приоритет WAN)
  lte-soft-fail [observe_sec]
  lte-recover-ladder [observe_sec]
  lte-apn-firstboot [observe_sec]
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
    echo
    echo "diag:"
    ls -1 "$TESTS_ROOT/diag"/*.sh 2>/dev/null | xargs -n1 basename
    ;;
  snap|snapshot)
    bash "$TESTS_ROOT/diag/snapshot.sh" "$@"
    ;;
  status|health|service)
    bash "$TESTS_ROOT/diag/status.sh" "$@"
    ;;
  dhcp|dhcp-lan|lan-dhcp)
    bash "$TESTS_ROOT/diag/dhcp-lan.sh" "$@"
    ;;
  boot-timeline|timeline)
    bash "$TESTS_ROOT/diag/boot-timeline.sh" "$@"
    ;;
  events|log)
    bash "$TESTS_ROOT/diag/recent-events.sh" "$@"
    ;;
  recover-selftest|recover-lib)
    bash "$TESTS_ROOT/diag/recover-lib-selftest.sh" "$@"
    ;;
  sysctl-panic|panic-sysctl)
    bash "$TESTS_ROOT/diag/sysctl-panic.sh" "$@"
    ;;
  panic-reboot)
    bash "$TESTS_ROOT/scenarios/panic-reboot.sh" "$@"
    ;;
  wan-failover|wan)
    bash "$TESTS_ROOT/scenarios/wan-failover.sh" "$@"
    ;;
  vpn-lte-boot|vpn-boot)
    bash "$TESTS_ROOT/scenarios/vpn-lte-boot.sh" "$@"
    ;;
  reboot-wan)
    bash "$TESTS_ROOT/scenarios/reboot-wan.sh" "$@"
    ;;
  reboot-lte)
    bash "$TESTS_ROOT/scenarios/reboot-lte.sh" "$@"
    ;;
  reboot-both)
    bash "$TESTS_ROOT/scenarios/reboot-both.sh" "$@"
    ;;
  lte-soft-fail|lte-soft)
    bash "$TESTS_ROOT/scenarios/lte-soft-fail.sh" "$@"
    ;;
  lte-recover-ladder|lte-ladder|recover-ladder)
    bash "$TESTS_ROOT/scenarios/lte-recover-ladder.sh" "$@"
    ;;
  lte-apn-firstboot|apn-firstboot)
    bash "$TESTS_ROOT/scenarios/lte-apn-firstboot.sh" "$@"
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
