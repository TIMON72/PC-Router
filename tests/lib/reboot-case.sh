#!/usr/bin/env bash
# Общая логика reboot-сценариев: arm → reboot → verify oneshot пишет result в state/.
# shellcheck shell=bash

: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
: "${WAN_IF:=enp3s0}"
: "${LTE_IF:=ppp0}"
: "${VPN_IF:=tun0}"
: "${EDGE_MODE:=vpn}"
: "${OPENVPN_UNIT:=openvpn@vpn.service}"
: "${LTE_UNIT:=lte.service}"

REBOOT_TEST_DIR="${REBOOT_STATE_DIR:-$SYSTEMA_ROUTER_ROOT/state}"
REBOOT_PENDING="$REBOOT_TEST_DIR/reboot-test.pending"
REBOOT_RESULT="$REBOOT_TEST_DIR/reboot-test.result"
REBOOT_OUT="$REBOOT_TEST_DIR/reboot-test.out"
REBOOT_HOLD_UNIT=pc-router-reboot-hold-wan.service
REBOOT_VERIFY_UNIT=pc-router-reboot-verify.service
REBOOT_HOLD_SCRIPT=/usr/local/sbin/pc-router-reboot-hold-wan.sh
REBOOT_VERIFY_SCRIPT=/usr/local/sbin/pc-router-reboot-verify.sh

reboot_test_vpn_ok() {
  if [[ "${EDGE_MODE}" != "vpn" ]]; then
    return 0
  fi
  if [[ -n "${VPN_PING_HOST:-}" ]]; then
    ping -c 1 -W 3 "$VPN_PING_HOST" >/dev/null 2>&1
  else
    ip -4 addr show "$VPN_IF" 2>/dev/null | grep -q inet
  fi
}

reboot_test_disarm() {
  systemctl disable --now "$REBOOT_HOLD_UNIT" 2>/dev/null || true
  systemctl disable --now "$REBOOT_VERIFY_UNIT" 2>/dev/null || true
  rm -f "/etc/systemd/system/$REBOOT_HOLD_UNIT" \
    "/etc/systemd/system/$REBOOT_VERIFY_UNIT" \
    "$REBOOT_HOLD_SCRIPT" "$REBOOT_VERIFY_SCRIPT" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  rm -f /tmp/hold-wan-down
  ip link set "$WAN_IF" up 2>/dev/null || true
  networkctl up "$WAN_IF" 2>/dev/null || true
  # LTE могла быть отключена в режиме wan
  systemctl enable "$LTE_UNIT" 2>/dev/null || true
  systemctl start "$LTE_UNIT" 2>/dev/null || true
}

reboot_test_install_units() {
  local mode="$1" observe="$2"
  mkdir -p "$REBOOT_TEST_DIR"

  cat >"$REBOOT_HOLD_SCRIPT" <<EOF
#!/bin/bash
set -u
ROOT="$SYSTEMA_ROUTER_ROOT"
PENDING="\$ROOT/state/reboot-test.pending"
WAN_IF="$WAN_IF"
[[ -f "\$PENDING" ]] || exit 0
# shellcheck disable=SC1090
source "\$PENDING"
if [[ "\${MODE:-}" == "lte" ]]; then
  touch /tmp/hold-wan-down
  ip link set "\$WAN_IF" down 2>/dev/null || true
  logger -t systema-router -- "REBOOT_TEST hold WAN for lte mode"
fi
exit 0
EOF
  chmod 755 "$REBOOT_HOLD_SCRIPT"

  cat >"$REBOOT_VERIFY_SCRIPT" <<EOF
#!/bin/bash
set -u
export SYSTEMA_ROUTER_ROOT="$SYSTEMA_ROUTER_ROOT"
# shellcheck disable=SC1091
source "\$SYSTEMA_ROUTER_ROOT/tests/lib/common.sh"
# shellcheck disable=SC1091
source "\$SYSTEMA_ROUTER_ROOT/tests/lib/reboot-case.sh"
reboot_test_verify_main
EOF
  chmod 755 "$REBOOT_VERIFY_SCRIPT"

  cat >"/etc/systemd/system/$REBOOT_HOLD_UNIT" <<EOF
[Unit]
Description=PC-Router reboot-test: hold WAN early (lte mode)
DefaultDependencies=no
After=local-fs.target
Before=network.target lte.service

[Service]
Type=oneshot
ExecStart=$REBOOT_HOLD_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat >"/etc/systemd/system/$REBOOT_VERIFY_UNIT" <<EOF
[Unit]
Description=PC-Router reboot-test: verify after boot
After=network-online.target lte-failover.service
Wants=network-online.target
# openvpn может подняться позже — verify сам ждёт

[Service]
Type=oneshot
ExecStart=$REBOOT_VERIFY_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  {
    echo "MODE=$mode"
    echo "OBSERVE=$observe"
    echo "STARTED_TS=$(date +%s)"
  } >"$REBOOT_PENDING"

  rm -f "$REBOOT_RESULT"
  : >"$REBOOT_OUT"
  systemctl daemon-reload
  systemctl enable "$REBOOT_HOLD_UNIT" "$REBOOT_VERIFY_UNIT"
}

reboot_test_log() {
  local line="$1"
  echo "$line" | tee -a "$REBOOT_OUT"
  logger -t systema-router -- "REBOOT_TEST $line" 2>/dev/null || true
}

reboot_test_verify_main() {
  local mode observe deadline now path_ok=0 vpn_ok=0 code=1
  mkdir -p "$REBOOT_TEST_DIR"
  exec >>"$REBOOT_OUT" 2>&1
  echo "===== REBOOT VERIFY $(date -Is) ====="

  if [[ ! -f "$REBOOT_PENDING" ]]; then
    echo "no pending — skip"
    reboot_test_disarm
    exit 0
  fi
  # shellcheck disable=SC1090
  source "$REBOOT_PENDING"
  mode="${MODE:-both}"
  observe="${OBSERVE:-180}"
  deadline=$(( $(date +%s) + observe ))

  netlog REBOOT_TEST_VERIFY "Проверка после reboot" mode="$mode" observe_s="$observe"

  case "$mode" in
    wan)
      # LTE был disabled до reboot
      ;;
    lte)
      touch /tmp/hold-wan-down
      ip link set "$WAN_IF" down 2>/dev/null || true
      ;;
    both) ;;
    *)
      echo "FAIL unknown MODE=$mode"
      echo 1 >"$REBOOT_RESULT"
      reboot_test_disarm
      exit 1
      ;;
  esac

  while (( $(date +%s) < deadline )); do
    path_ok=0
    vpn_ok=0
    case "$mode" in
      wan|both)
        if on_wan_path && ping -I "$WAN_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
          path_ok=1
        fi
        ;;
      lte)
        if on_lte_path && ping -I "$LTE_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
          path_ok=1
        fi
        ;;
    esac
    if reboot_test_vpn_ok; then
      vpn_ok=1
    fi
    if [[ "$path_ok" -eq 1 && "$vpn_ok" -eq 1 ]]; then
      code=0
      break
    fi
    sleep 5
  done

  now="$(date -Is)"
  if [[ "$code" -eq 0 ]]; then
    echo "PASS reboot-$mode path_ok=$path_ok vpn_ok=$vpn_ok at $now"
    netlog REBOOT_TEST_PASS "Reboot-сценарий OK" mode="$mode"
  else
    echo "FAIL reboot-$mode path_ok=$path_ok vpn_ok=$vpn_ok at $now"
    snap "REBOOT_FAIL_$mode"
    netlog REBOOT_TEST_FAIL "Reboot-сценарий FAIL" mode="$mode" path_ok="$path_ok" vpn_ok="$vpn_ok"
  fi

  echo "$code" >"$REBOOT_RESULT"
  rm -f "$REBOOT_PENDING"
  # Восстановление окружения
  rm -f /tmp/hold-wan-down
  ip link set "$WAN_IF" up 2>/dev/null || true
  networkctl up "$WAN_IF" 2>/dev/null || true
  systemctl enable "$LTE_UNIT" 2>/dev/null || true
  systemctl start "$LTE_UNIT" 2>/dev/null || true
  if [[ "${EDGE_MODE}" == "vpn" ]]; then
    systemctl start "$OPENVPN_UNIT" 2>/dev/null || true
  fi
  reboot_test_disarm
  exit "$code"
}

# Arm + preconditions + reboot (вызывается из scenarios/)
reboot_test_run() {
  local mode="$1"
  local observe="${2:-180}"

  require_root
  if [[ "${EDGE_MODE}" != "vpn" ]]; then
    skip_test "EDGE_MODE=$EDGE_MODE (need vpn)"
  fi

  case "$mode" in
    wan) require_uplinks vpn wan ;;
    lte) require_uplinks vpn lte ;;
    both) require_uplinks vpn wan lte ;;
  esac

  echo "===== REBOOT-$mode START $(date -Is) observe=${observe}s ====="
  netlog TEST_START "Сценарий reboot-$mode" observe_s="$observe"

  # Снять хвосты прошлого прогона
  reboot_test_disarm
  rm -f "$REBOOT_RESULT" "$REBOOT_PENDING"
  : >"$REBOOT_OUT"

  case "$mode" in
    wan)
      # Только WAN: LTE не должен поднять default после boot
      systemctl stop "$LTE_UNIT" 2>/dev/null || true
      systemctl disable "$LTE_UNIT" 2>/dev/null || true
      restore_wan
      sleep 2
      if ! ping -I "$WAN_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "FAIL: WAN недоступен до reboot"
        netlog TEST_END "reboot-wan abort" reason=no_wan
        exit 1
      fi
      ;;
    lte)
      systemctl start "$LTE_UNIT" 2>/dev/null || true
      # До reboot убедимся, что LTE вообще умеет ходить
      touch /tmp/hold-wan-down
      ip link set "$WAN_IF" down 2>/dev/null || true
      local d=$(( $(date +%s) + 90 ))
      local lte_ok=0
      while (( $(date +%s) < d )); do
        assert_uplinks_still lte
        if ping -I "$LTE_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
          lte_ok=1
          break
        fi
        sleep 3
      done
      if [[ "$lte_ok" -ne 1 ]]; then
        echo "FAIL: LTE недоступен до reboot"
        restore_wan
        netlog TEST_END "reboot-lte abort" reason=no_lte
        exit 1
      fi
      ;;
    both)
      systemctl enable --now "$LTE_UNIT" 2>/dev/null || true
      restore_wan
      sleep 2
      if ! ping -I "$WAN_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "FAIL: WAN недоступен до reboot (both)"
        exit 1
      fi
      ;;
    *)
      echo "usage: reboot_test_run wan|lte|both [observe_sec]" >&2
      exit 2
      ;;
  esac

  reboot_test_install_units "$mode" "$observe"
  sync
  netlog REBOOT_TEST_ARM "Arm reboot-test" mode="$mode" observe_s="$observe"
  echo ">>> systemctl reboot (verify oneshot after boot, result → $REBOOT_RESULT)"
  # Несколько секунд на flush логов
  sleep 2
  systemctl reboot
  # Если reboot не сработал:
  sleep 30
  echo "FAIL: reboot did not happen"
  echo 1 >"$REBOOT_RESULT"
  reboot_test_disarm
  exit 1
}
