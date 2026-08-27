#!/usr/bin/env bash
# Общие хелперы для tests/ (только на устройстве)
# shellcheck shell=bash

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEMA_ROUTER_ROOT="${SYSTEMA_ROUTER_ROOT:-/home/admin/PC-Router}"
CONFIG_FILE="${CONFIG_FILE:-$SYSTEMA_ROUTER_ROOT/config.env}"
TEST_ENV_FILE="${TEST_ENV_FILE:-/run/systema-router/test.env}"
TEST_ENV_BAK="${TEST_ENV_BAK:-/run/systema-router/test.env.bak}"
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
NETLOG_FILE="${NETLOG_FILE:-$SYSTEMA_ROUTER_ROOT/logs.log}"

WAN_IF="${WAN_IF:-enp3s0}"
LTE_IF="${LTE_IF:-ppp0}"
LAN_IF="${LAN_IF:-enp4s0}"
VPN_IF="${VPN_IF:-tun0}"
EDGE_MODE="${EDGE_MODE:-vpn}"
WHITE_IF="${WHITE_IF:-$WAN_IF}"
OPENVPN_UNIT="${OPENVPN_UNIT:-openvpn@vpn.service}"
LTE_UNIT="${LTE_UNIT:-lte.service}"

# shellcheck disable=SC1091
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/netlog.sh" 2>/dev/null || true
type netlog >/dev/null 2>&1 || netlog() { :; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Нужен root: sudo bash $0 $*" >&2
    exit 1
  fi
}

ts() { date -Is; }

snap() {
  local label="${1:-SNAP}"
  echo "=== $label $(ts) ==="
  ip -br a | grep -E "${WAN_IF}|${LTE_IF}|${VPN_IF}|${LAN_IF}" || true
  echo "-- routes --"
  ip route | grep -E "default|${LTE_IF}|${WAN_IF}" || true
  echo "-- state --"
  cat /run/lte-failover.state 2>/dev/null || echo "(no failover state)"
  echo "-- apn --"
  "$SYSTEMA_ROUTER_ROOT/scripts/lte-apn-select.sh" show 2>/dev/null | head -5 || true
  echo "-- services --"
  case "$EDGE_MODE" in
    vpn) systemctl is-active "$LTE_UNIT" lte-failover.service "$OPENVPN_UNIT" network-failsafe.timer 2>/dev/null || true ;;
    *) systemctl is-active "$LTE_UNIT" lte-failover.service network-failsafe.timer 2>/dev/null || true ;;
  esac
  echo "-- ping --"
  ping -I "$WAN_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "WAN_IF_OK" || echo "WAN_IF_FAIL"
  ping -I "$LTE_IF" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "LTE_IF_OK" || echo "LTE_IF_FAIL"
  ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "DEFAULT_OK" || echo "DEFAULT_FAIL"
  case "$EDGE_MODE" in
    vpn)
      if ip -4 addr show "$VPN_IF" 2>/dev/null | grep -q inet; then
        if [[ -n "${VPN_PING_HOST:-}" ]]; then
          ping -c 1 -W 3 "$VPN_PING_HOST" >/dev/null 2>&1 && echo "VPN_OK" || echo "VPN_FAIL"
        else
          echo "VPN_IF_UP"
        fi
      else
        echo "VPN_DOWN"
      fi
      ;;
    whiteip)
      if [[ -n "${WHITE_IP:-}" ]] && ip -4 -o addr show dev "$WHITE_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$WHITE_IP"; then
        echo "WHITEIP_OK"
      elif [[ -z "${WHITE_IP:-}" ]] && ip -4 addr show "$WHITE_IF" 2>/dev/null | grep -q inet; then
        echo "WHITEIP_IF_UP"
      else
        echo "WHITEIP_DOWN"
      fi
      ;;
    none)
      echo "EDGE_NONE"
      ;;
  esac
}

log_tail() {
  local n="${1:-30}"
  local tag="${2:-}"
  if [[ -n "$tag" ]]; then
    grep -E "$tag" "$NETLOG_FILE" 2>/dev/null | tail -n "$n" || true
  else
    tail -n "$n" "$NETLOG_FILE" 2>/dev/null || true
  fi
}

# Применить fixture (key=value) в test.env и перезапустить long-running failover
# Usage: test_env_begin [fixture.env] [KEY=VAL ...]
test_env_begin() {
  local fixture="${1:-}"
  [[ $# -gt 0 ]] && shift || true
  mkdir -p "$(dirname "$TEST_ENV_FILE")"
  if [[ -f "$TEST_ENV_FILE" ]]; then
    cp -a "$TEST_ENV_FILE" "$TEST_ENV_BAK"
  else
    rm -f "$TEST_ENV_BAK"
  fi
  {
    echo "# systema-router test overlay $(ts)"
    echo "TEST_ACTIVE=1"
    if [[ -n "$fixture" && -f "$fixture" ]]; then
      cat "$fixture"
    fi
    local arg
    for arg in "$@"; do
      [[ "$arg" == *=* ]] && echo "$arg"
    done
  } >"$TEST_ENV_FILE"
  chmod 644 "$TEST_ENV_FILE"
  netlog TEST_ENV "Включён test.env" file="$TEST_ENV_FILE"
  systemctl restart lte-failover.service 2>/dev/null || true
}

test_env_end() {
  rm -f "$TEST_ENV_FILE"
  if [[ -f "$TEST_ENV_BAK" ]]; then
    mv -f "$TEST_ENV_BAK" "$TEST_ENV_FILE"
  fi
  netlog TEST_ENV_CLEAR "Снят test.env"
  systemctl restart lte-failover.service 2>/dev/null || true
}

restore_wan() {
  rm -f /tmp/hold-wan-down
  ip link set "$WAN_IF" up 2>/dev/null || true
  networkctl up "$WAN_IF" 2>/dev/null || true
  networkctl reconfigure "$WAN_IF" 2>/dev/null || true
}

clear_icmp_drop_lte() {
  iptables -D OUTPUT -o "$LTE_IF" -p icmp -j DROP 2>/dev/null || true
  iptables -D INPUT -i "$LTE_IF" -p icmp -j DROP 2>/dev/null || true
}

on_lte_path() {
  grep -q '^path=lte$' /run/lte-failover.state 2>/dev/null \
    || ip route show default 2>/dev/null | grep -qE "dev ${LTE_IF} metric 100"
}

on_wan_path() {
  grep -q '^path=wan$' /run/lte-failover.state 2>/dev/null \
    && ip route show default 2>/dev/null | grep -qE "dev ${WAN_IF}"
}

# --- Preflight / SKIP (exit 77) ---
# Suite (deploy) мапит 77 → статус SKIP, не FAIL.
SKIP_RC=77

skip_test() {
  local reason="$*"
  echo "SKIP ${reason}"
  netlog TEST_SKIP "Сценарий пропущен" reason="$reason" 2>/dev/null || true
  exit "$SKIP_RC"
}

iface_exists() {
  local ifc="$1"
  [[ -d "/sys/class/net/${ifc}" ]]
}

# WAN: кабель вставлен (carrier). operstate=up — запасной признак.
wan_cable_present() {
  iface_exists "$WAN_IF" || return 1
  [[ "$(cat "/sys/class/net/${WAN_IF}/carrier" 2>/dev/null || echo 0)" == "1" ]]
}

wan_phys_ok() {
  iface_exists "$WAN_IF" || return 1
  wan_cable_present && return 0
  [[ "$(cat "/sys/class/net/${WAN_IF}/operstate" 2>/dev/null || echo down)" == "up" ]]
}

# LTE железо: ppp iface или USB-модем (ttyUSB*).
lte_hw_ok() {
  iface_exists "$LTE_IF" && return 0
  compgen -G '/dev/ttyUSB*' >/dev/null 2>&1 && return 0
  compgen -G '/dev/ttyACM*' >/dev/null 2>&1 && return 0
  return 1
}

# LTE с IPv4 (уже поднят data path).
lte_data_ok() {
  iface_exists "$LTE_IF" || return 1
  ip -4 addr show "$LTE_IF" 2>/dev/null | grep -q 'inet '
}

# Тест сам держит WAN down — не считать это «потерей оператора».
wan_hold_active() {
  [[ -f /tmp/hold-wan-down ]]
}

# require_uplinks wan [lte] [vpn]
# До старта сценария: нет нужного uplink → SKIP.
require_uplinks() {
  local need
  for need in "$@"; do
    case "$need" in
      wan)
        if ! wan_phys_ok; then
          skip_test "no WAN ($WAN_IF down/unplugged/missing)"
        fi
        ;;
      lte)
        if ! lte_hw_ok; then
          skip_test "no LTE hardware (no $LTE_IF / ttyUSB*)"
        fi
        ;;
      lte-data)
        if ! lte_data_ok; then
          # Попробуем коротко поднять сервис — если не вышло, SKIP
          systemctl start "$LTE_UNIT" 2>/dev/null || true
          sleep 5
          if ! lte_data_ok; then
            skip_test "no LTE data ($LTE_IF without IPv4)"
          fi
        fi
        ;;
      vpn)
        if [[ "${EDGE_MODE:-}" != "vpn" ]]; then
          skip_test "EDGE_MODE=${EDGE_MODE:-} (need vpn)"
        fi
        ;;
      *)
        echo "require_uplinks: unknown token '$need'" >&2
        exit 2
        ;;
    esac
  done
}

# Mid-test: нужный uplink пропал не из-за hold теста.
# По умолчанию FAIL. TEST_MID_DISCONNECT=skip → SKIP (удобно при ручных экспериментах).
# Usage: assert_uplinks_still wan|lte|lte-data ...
assert_uplinks_still() {
  local need ok=1 why=""
  for need in "$@"; do
    case "$need" in
      wan)
        if wan_hold_active; then
          continue
        fi
        # Admin down (failover-тест) при живом кабеле — не «оператор выдернул».
        if wan_cable_present; then
          continue
        fi
        if ! wan_phys_ok; then
          ok=0
          why="WAN lost mid-test ($WAN_IF)"
        fi
        ;;
      lte|lte-data)
        if [[ "$need" == "lte-data" ]]; then
          lte_data_ok || { ok=0; why="LTE data lost mid-test ($LTE_IF)"; }
        else
          lte_hw_ok || { ok=0; why="LTE hardware lost mid-test"; }
        fi
        ;;
      *)
        echo "assert_uplinks_still: unknown token '$need'" >&2
        exit 2
        ;;
    esac
  done
  [[ "$ok" -eq 1 ]] && return 0
  echo "UPLINK_GONE ${why}"
  netlog TEST_UPLINK_GONE "$why" 2>/dev/null || true
  if [[ "${TEST_MID_DISCONNECT:-fail}" == "skip" ]]; then
    skip_test "$why (operator disconnect)"
  fi
  echo "FAIL ${why}"
  exit 1
}

# Алиас: часть сценариев ссылается на TESTS_ROOT
TESTS_ROOT="$TESTS_ROOT"
