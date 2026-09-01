#!/usr/bin/env bash
# Общее логирование systema-router
# Использование: source $SYSTEMA_ROUTER_ROOT/scripts/lib/netlog.sh
#   netlog EVENT message key=value ...

NETLOG_DIR="${NETLOG_DIR:-/home/admin/PC-Router}"
NETLOG_FILE="${NETLOG_FILE:-$NETLOG_DIR/logs.log}"
NETLOG_STATE_DIR="${NETLOG_STATE_DIR:-/run/systema-router}"

netlog_init() {
    mkdir -p "$NETLOG_DIR" "$NETLOG_STATE_DIR" 2>/dev/null || true
    touch "$NETLOG_FILE" 2>/dev/null || true
    chmod 666 "$NETLOG_FILE" 2>/dev/null || true
    # чтобы admin видел лог в домашнем проекте
    if [[ "$NETLOG_FILE" == /home/admin/* ]]; then
        chown admin:admin "$NETLOG_FILE" 2>/dev/null || true
    fi
}

# netlog EVENT "human message" [k=v ...]
netlog() {
    local event="$1"
    shift
    local msg="${1:-}"
    shift || true
    local ts extras="" pri=local0.info
    ts="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    local kv
    for kv in "$@"; do
        extras+=" ${kv}"
    done
    case "$event" in
      OUTAGE_WARN|REBOOT|LTE_RESTART_FAIL|NO_UPLINK)
        pri=local0.warning
        ;;
    esac
    netlog_init
    # CSV-friendly: timestamp|event|message|k=v...
    printf '%s|%s|%s|%s\n' "$ts" "$event" "$msg" "${extras# }" >>"$NETLOG_FILE" 2>/dev/null || true
    logger -t systema-router -p "$pri" -- "${event}: ${msg}${extras}" 2>/dev/null || true
    # Persistent boot/path trail (survives volatile journal after hard power-off)
    case "$event" in
      FAILOVER_START|LTE_IPUP|VPN_RESTART|PATH_SWITCH|WAN_UP|WAN_DOWN|LTE_UP|LTE_DOWN|VPN_UP|VPN_DOWN|OUTAGE_WARN|OUTAGE_START|OUTAGE_CLEAR|REBOOT|REBOOT_SCHEDULED|REBOOT_TEST_ARM|REBOOT_TEST_VERIFY|REBOOT_TEST_PASS|REBOOT_TEST_FAIL)
        local timeline="${REBOOT_STATE_DIR:-${SYSTEMA_ROUTER_ROOT:-/home/admin/PC-Router}/state}/boot-timeline.log"
        mkdir -p "$(dirname "$timeline")" 2>/dev/null || true
        printf '%s|%s|%s|%s\n' "$ts" "$event" "$msg" "${extras# }" >>"$timeline" 2>/dev/null || true
        ;;
    esac
}

# Логировать только при смене состояния (edge-trigger)
# netlog_edge STATE_KEY new_value EVENT_UP EVENT_DOWN "msg up" "msg down" [k=v...]
netlog_edge() {
    local key="$1" new="$2" ev_up="$3" ev_down="$4" msg_up="$5" msg_down="$6"
    shift 6 || true
    netlog_init
    local f="$NETLOG_STATE_DIR/edge.${key}"
    local old=""
    [[ -f "$f" ]] && old="$(cat "$f" 2>/dev/null || true)"
    if [[ "$old" == "$new" ]]; then
        return 0
    fi
    echo "$new" >"$f"
    if [[ "$new" == "1" || "$new" == "up" || "$new" == "ok" ]]; then
        netlog "$ev_up" "$msg_up" "$@"
    else
        netlog "$ev_down" "$msg_down" "$@"
    fi
}
