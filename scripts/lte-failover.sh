#!/usr/bin/env bash
# Failover WAN <-> LTE + мониторинг edge (VPN/whiteip) + логирование + авто-APN
set -u
# shellcheck disable=SC1091
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh"
type netlog >/dev/null 2>&1 || netlog() { :; }

# shellcheck disable=SC1091

WAN_IF="${WAN_IF:-enp3s0}"
LTE_IF="${LTE_IF:-ppp0}"
LAN_IF="${LAN_IF:-enp4s0}"
VPN_IF="${VPN_IF:-tun0}"
# vpn | whiteip | none
EDGE_MODE="${EDGE_MODE:-vpn}"
WHITE_IF="${WHITE_IF:-$WAN_IF}"
WHITE_IP="${WHITE_IP:-}"
WHITE_PING_HOST="${WHITE_PING_HOST:-}"
PING_HOST="${PING_HOST:-8.8.8.8}"
PING_HOST_ALT="${PING_HOST_ALT:-1.1.1.1}"
# Опционально: доп. хост для check_internet (пусто = не использовать)
EDGE_CHECK_HOST="${EDGE_CHECK_HOST:-${VPN_CHECK_HOST:-}}"
VPN_PING_HOST="${VPN_PING_HOST:-}"
PING_COUNT="${PING_COUNT:-2}"
PING_TIMEOUT="${PING_TIMEOUT:-2}"
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
RECOVER_THRESHOLD="${RECOVER_THRESHOLD:-2}"
MIN_SWITCH_INTERVAL="${MIN_SWITCH_INTERVAL:-20}"
LTE_RESTART_COOLDOWN="${LTE_RESTART_COOLDOWN:-300}"
VPN_RESTART_COOLDOWN="${VPN_RESTART_COOLDOWN:-60}"
STATE_FILE="${STATE_FILE:-/run/lte-failover.state}"
LOG_FILE="${LOG_FILE:-/home/admin/PC-Router/lte-failover.log}"
OPENVPN_UNIT="${OPENVPN_UNIT:-openvpn@vpn.service}"
LTE_UNIT="${LTE_UNIT:-lte.service}"
LAN_NET="${LAN_NET:-192.168.50.0/24}"
APN_SELECT_BIN="${LTE_APN_SELECT:-$SYSTEMA_ROUTER_ROOT/scripts/lte-apn-select.sh}"
# Менять APN только после N «мягких» провалов подряд (модем на месте, но нет интернета)
APN_NEXT_AFTER_FAILS="${APN_NEXT_AFTER_FAILS:-3}"
SOFT_FAIL_FILE="${NETLOG_STATE_DIR:-/run/systema-router}/lte.softfail"
# Оверрайды ускоренных тестов (tests/ → /run/systema-router/test.env)
# shellcheck disable=SC1091
[[ -f /run/systema-router/test.env ]] && source /run/systema-router/test.env

# Нормализация режима
case "$EDGE_MODE" in
  vpn|whiteip|none) ;;
  *) EDGE_MODE=vpn ;;
esac

wan_ok_streak=0
lte_ok_streak=0
wan_fail_streak=0
lte_fail_streak=0
vpn_fail_streak=0
last_switch_ts=0
last_lte_restart_ts=0
last_vpn_restart_ts=0
current_path="unknown"
lte_restart_pid=""

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG_FILE")" 2>/dev/null || true
netlog_init

log() {
    local msg="$1"
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') - $msg"
    echo "$line" | tee -a "$LOG_FILE" >/dev/null
    echo "$line"
}

save_state() {
    current_path="$1"
    cat >"$STATE_FILE" <<EOF
path=$current_path
updated=$(date +%s)
wan_ok_streak=$wan_ok_streak
lte_ok_streak=$lte_ok_streak
wan_fail_streak=$wan_fail_streak
lte_fail_streak=$lte_fail_streak
vpn_fail_streak=$vpn_fail_streak
last_switch_ts=$last_switch_ts
last_lte_restart_ts=$last_lte_restart_ts
last_vpn_restart_ts=$last_vpn_restart_ts
EOF
}

load_state() {
    [[ -f "$STATE_FILE" ]] || return 0
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            path) current_path="$v" ;;
            wan_ok_streak) wan_ok_streak="$v" ;;
            lte_ok_streak) lte_ok_streak="$v" ;;
            wan_fail_streak) wan_fail_streak="$v" ;;
            lte_fail_streak) lte_fail_streak="$v" ;;
            vpn_fail_streak) vpn_fail_streak="$v" ;;
            last_switch_ts) last_switch_ts="$v" ;;
            last_lte_restart_ts) last_lte_restart_ts="$v" ;;
            last_vpn_restart_ts) last_vpn_restart_ts="$v" ;;
        esac
    done <"$STATE_FILE"
}

iface_has_ipv4() { ip -4 addr show "$1" 2>/dev/null | grep -q 'inet '; }
iface_exists() { ip link show "$1" >/dev/null 2>&1; }

ping_via() {
    ping -I "$1" -c 1 -W "$PING_TIMEOUT" "$2" >/dev/null 2>&1
}

check_internet_on() {
    local iface="$1" host i
    for host in "$PING_HOST" "$PING_HOST_ALT"; do
        for ((i = 1; i <= PING_COUNT; i++)); do
            ping_via "$iface" "$host" && return 0
        done
    done
    if [[ -n "${EDGE_CHECK_HOST:-}" ]]; then
        ping_via "$iface" "$EDGE_CHECK_HOST" && return 0
    fi
    return 1
}

get_gateway() {
    local iface="$1" gw=""
    if command -v networkctl >/dev/null 2>&1; then
        gw="$(networkctl status "$iface" 2>/dev/null | awk '/Gateway:/{print $2; exit}')"
    fi
    [[ -z "$gw" ]] && gw="$(ip -4 route show dev "$iface" 2>/dev/null | awk '/default/{print $3; exit}')"
    if [[ -z "$gw" ]]; then
        local ip_addr
        ip_addr="$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
        [[ -n "$ip_addr" ]] && gw="$(echo "$ip_addr" | awk -F. '{print $1"."$2"."$3".1"}')"
    fi
    echo "$gw"
}

can_switch() {
    local now; now="$(date +%s)"
    [[ $((now - last_switch_ts)) -ge $MIN_SWITCH_INTERVAL ]]
}

can_restart_lte() {
    local now; now="$(date +%s)"
    [[ $((now - last_lte_restart_ts)) -ge $LTE_RESTART_COOLDOWN ]]
}

can_restart_vpn() {
    local now; now="$(date +%s)"
    [[ $((now - last_vpn_restart_ts)) -ge $VPN_RESTART_COOLDOWN ]]
}

ensure_nat_for_uplink() {
    local uplink="$1"
    if ! iptables -t nat -C POSTROUTING -o "$uplink" -s "$LAN_NET" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$uplink" -s "$LAN_NET" -j MASQUERADE
        log "NAT: MASQUERADE -o $uplink"
        netlog NAT_ADD "Добавлен MASQUERADE" iface="$uplink" lan="$LAN_NET"
    fi
}

clear_defaults_via() {
    local iface="$1" line
    while read -r line; do
        [[ -z "$line" ]] && continue
        # shellcheck disable=SC2086
        ip route del $line 2>/dev/null || true
    done < <(ip route show default 2>/dev/null | grep " dev ${iface} " || true)
}

wan_link_ready() {
    local state
    state="$(cat /sys/class/net/${WAN_IF}/operstate 2>/dev/null || echo down)"
    [[ "$state" == "up" ]] && iface_has_ipv4 "$WAN_IF"
}

iface_has_addr() {
    local iface="$1" addr="$2"
    ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$addr"
}

# Внешний доступ OK: VPN-туннель или белый IP (или none = всегда OK)
edge_ready() {
    case "$EDGE_MODE" in
      none)
        return 0
        ;;
      whiteip)
        local wif="${WHITE_IF:-$WAN_IF}"
        iface_exists "$wif" || return 1
        if [[ -n "${WHITE_IP:-}" ]]; then
            iface_has_addr "$wif" "$WHITE_IP" || return 1
        else
            iface_has_ipv4 "$wif" || return 1
        fi
        if [[ -n "${WHITE_PING_HOST:-}" ]]; then
            ping -c 1 -W "$PING_TIMEOUT" "$WHITE_PING_HOST" >/dev/null 2>&1 || return 1
        fi
        return 0
        ;;
      vpn)
        iface_exists "$VPN_IF" && iface_has_ipv4 "$VPN_IF" || return 1
        if [[ -n "${VPN_PING_HOST:-}" ]]; then
            ping -c 1 -W "$PING_TIMEOUT" "$VPN_PING_HOST" >/dev/null 2>&1 || return 1
        fi
        return 0
        ;;
      *)
        return 0
        ;;
    esac
}

set_wan_route() {
    local gw="$1"
    log "Переключение на WAN ($WAN_IF) через $gw"
    netlog PATH_SWITCH "Активный uplink → WAN" from="$current_path" to="wan" gw="$gw" iface="$WAN_IF"
    ip route replace default via "$gw" dev "$WAN_IF" metric 100
    if iface_exists "$LTE_IF"; then
        clear_defaults_via "$LTE_IF"
        ip route replace default dev "$LTE_IF" metric 500 2>/dev/null || true
    fi
    ensure_nat_for_uplink "$WAN_IF"
    last_switch_ts="$(date +%s)"
    save_state "wan"
    force_restart_edge "path_switch_wan"
}

set_lte_route() {
    log "Переключение на LTE ($LTE_IF)"
    netlog PATH_SWITCH "Активный uplink → LTE" from="$current_path" to="lte" iface="$LTE_IF"
    clear_defaults_via "$WAN_IF"
    ip route replace default dev "$LTE_IF" metric 100
    ensure_nat_for_uplink "$LTE_IF"
    last_switch_ts="$(date +%s)"
    save_state "lte"
    force_restart_edge "path_switch_lte"
}

# Рестарт edge только для VPN (белый IP не рестартуем)
force_restart_edge() {
    local reason="${1:-manual}"
    [[ "$EDGE_MODE" == "vpn" ]] || return 0
    if ! can_restart_vpn; then
        log "VPN force-restart отложен (cooldown) reason=$reason"
        return 0
    fi
    last_vpn_restart_ts="$(date +%s)"
    vpn_fail_streak=0
    log "Форс-перезапуск OpenVPN ($reason)"
    netlog VPN_RESTART "Перезапуск OpenVPN" unit="$OPENVPN_UNIT" reason="$reason" edge_mode="$EDGE_MODE"
    systemctl restart "$OPENVPN_UNIT" || true
}

lte_restart_running() {
    [[ -n "$lte_restart_pid" ]] && kill -0 "$lte_restart_pid" 2>/dev/null
}

modem_present() {
    local d="${LTE_MODEM_DEV:-/dev/ttyUSB0}"
    [[ -e "$d" ]] || ls /dev/ttyUSB* >/dev/null 2>&1
}

soft_fail_count() {
    [[ -f "$SOFT_FAIL_FILE" ]] && cat "$SOFT_FAIL_FILE" || echo 0
}

soft_fail_bump() {
    local n
    mkdir -p "$(dirname "$SOFT_FAIL_FILE")"
    n="$(soft_fail_count)"
    n=$((n + 1))
    echo "$n" >"$SOFT_FAIL_FILE"
    echo "$n"
}

soft_fail_reset() {
    mkdir -p "$(dirname "$SOFT_FAIL_FILE")"
    echo 0 >"$SOFT_FAIL_FILE"
}

restart_lte_stack_bg() {
    if lte_restart_running; then
        return 0
    fi
    if ! can_restart_lte; then
        log "LTE restart пропущен (cooldown)"
        return 1
    fi
    last_lte_restart_ts="$(date +%s)"
    save_state "${current_path:-lte}"

    local reason="no_internet"
    local change_apn=0
    if ! modem_present; then
        reason="usb_missing"
        netlog LTE_RESTART "Ожидание USB-модема / restart LTE" reason="$reason"
    else
        local fails
        fails="$(soft_fail_bump)"
        if [[ "$fails" -ge "$APN_NEXT_AFTER_FAILS" ]]; then
            change_apn=1
            soft_fail_reset
            reason="soft_fail_apn_next"
        else
            reason="soft_fail_keep_apn"
        fi
        netlog LTE_RESTART "Перезапуск LTE стека" reason="$reason" soft_fails="$fails" apn_next="$change_apn"
    fi
    log "Фоновый перезапуск LTE ($reason)"

    (
        # USB пропал: ждём возврат устройства, APN не меняем (та же SIM вероятнее всего)
        if [[ "$reason" == "usb_missing" ]]; then
            local w
            for ((w = 1; w <= 90; w++)); do
                if modem_present; then
                    netlog LTE_MODEM_BACK "USB-модем снова в системе" waited_s="$w"
                    break
                fi
                sleep 1
            done
            if ! modem_present; then
                netlog LTE_RESTART_FAIL "Модем так и не появился" waited_s=90
                exit 1
            fi
            [[ -x "$APN_SELECT_BIN" ]] && "$APN_SELECT_BIN" reapply-last >/dev/null 2>&1 || true
        elif [[ $change_apn -eq 1 ]]; then
            if [[ -x "$APN_SELECT_BIN" ]]; then
                "$APN_SELECT_BIN" next >/dev/null 2>&1 || true
                "$APN_SELECT_BIN" apply >/dev/null 2>&1 || true
            fi
        else
            [[ -x "$APN_SELECT_BIN" ]] && "$APN_SELECT_BIN" reapply-last >/dev/null 2>&1 || true
        fi

        systemctl restart "$LTE_UNIT" || true
        local i
        for ((i = 1; i <= 36; i++)); do
            if iface_has_ipv4 "$LTE_IF" && check_internet_on "$LTE_IF"; then
                soft_fail_reset
                [[ -x "$APN_SELECT_BIN" ]] && "$APN_SELECT_BIN" success >/dev/null 2>&1 || true
                netlog LTE_UP "LTE снова в сети после restart" iface="$LTE_IF" reason="$reason"
                if ! wan_link_ready || ! check_internet_on "$WAN_IF"; then
                    clear_defaults_via "$WAN_IF"
                    ip route replace default dev "$LTE_IF" metric 100
                    ensure_nat_for_uplink "$LTE_IF"
                    echo "lte" >"${STATE_FILE}.pathhint"
                fi
                if [[ "$EDGE_MODE" == "vpn" ]]; then
                    systemctl restart "$OPENVPN_UNIT" || true
                fi
                exit 0
            fi
            sleep 5
        done
        netlog LTE_RESTART_FAIL "LTE не поднялся после restart" iface="$LTE_IF" reason="$reason"
        exit 1
    ) &
    lte_restart_pid=$!
}

maybe_restart_edge() {
    # Для whiteip/none только мониторим; рестарт сервиса — только vpn
    if edge_ready; then
        vpn_fail_streak=0
        return 0
    fi
    [[ "$EDGE_MODE" == "vpn" ]] || return 0
    vpn_fail_streak=$((vpn_fail_streak + 1))
    if [[ $vpn_fail_streak -lt $FAIL_THRESHOLD ]]; then
        return 0
    fi
    if ! can_restart_vpn; then
        return 0
    fi
    if [[ $wan_ok_streak -eq 0 && $lte_ok_streak -eq 0 ]]; then
        return 0
    fi
    last_vpn_restart_ts="$(date +%s)"
    vpn_fail_streak=0
    log "Перезапуск OpenVPN (нет рабочего tun/peer)"
    netlog VPN_RESTART "Перезапуск OpenVPN" unit="$OPENVPN_UNIT" edge_mode="$EDGE_MODE"
    systemctl restart "$OPENVPN_UNIT" || true
}

# Снять только протухший hold (>3 мин), чтобы не ломать короткий тест,
# но и не оставлять устройство без WAN навсегда.
clear_stale_test_holds() {
    local f=/tmp/hold-wan-down
    [[ -f "$f" ]] || return 0
    local age=0 now
    now="$(date +%s)"
    age=$((now - $(stat -c %Y "$f" 2>/dev/null || echo "$now")))
    if [[ "$age" -gt 180 ]]; then
        rm -f "$f"
        netlog FAILSAFE "Снят протухший hold-wan-down" age_sec="$age"
        ip link set "$WAN_IF" up 2>/dev/null || true
        networkctl up "$WAN_IF" 2>/dev/null || true
    fi
}

load_state
log "=== LTE Failover запущен (WAN=$WAN_IF LTE=$LTE_IF EDGE_MODE=$EDGE_MODE) ==="
netlog FAILOVER_START "Сервис failover запущен" wan="$WAN_IF" lte="$LTE_IF" edge_mode="$EDGE_MODE" vpn="$VPN_IF" white_if="$WHITE_IF"

while true; do
    clear_stale_test_holds

    # подхват pathhint из фонового LTE restart
    if [[ -f "${STATE_FILE}.pathhint" ]]; then
        current_path="$(cat "${STATE_FILE}.pathhint")"
        rm -f "${STATE_FILE}.pathhint"
        last_switch_ts="$(date +%s)"
    fi

    wan_up=0
    lte_up=0

    if wan_link_ready && check_internet_on "$WAN_IF"; then
        wan_up=1
        wan_ok_streak=$((wan_ok_streak + 1))
        wan_fail_streak=0
    else
        wan_ok_streak=0
        wan_fail_streak=$((wan_fail_streak + 1))
    fi

    if iface_exists "$LTE_IF" && iface_has_ipv4 "$LTE_IF" && check_internet_on "$LTE_IF"; then
        lte_up=1
        lte_ok_streak=$((lte_ok_streak + 1))
        lte_fail_streak=0
        soft_fail_reset
        # success без спама: только обновить apn.last тихо раз в N циклов
        if [[ -x "$APN_SELECT_BIN" && $lte_ok_streak -eq 1 ]]; then
            "$APN_SELECT_BIN" success >/dev/null 2>&1 || true
        fi
    else
        lte_ok_streak=0
        lte_fail_streak=$((lte_fail_streak + 1))
    fi

    netlog_edge wan "$wan_up" WAN_UP WAN_DOWN \
        "WAN доступен" "WAN недоступен" iface="$WAN_IF"
    netlog_edge lte "$lte_up" LTE_UP LTE_DOWN \
        "LTE доступен" "LTE недоступен" iface="$LTE_IF"

    case "$EDGE_MODE" in
      vpn)
        if edge_ready; then
            netlog_edge vpn 1 VPN_UP VPN_DOWN "VPN туннель OK" "VPN туннель недоступен" iface="$VPN_IF"
            vpn_fail_streak=0
        else
            netlog_edge vpn 0 VPN_UP VPN_DOWN "VPN туннель OK" "VPN туннель недоступен" iface="$VPN_IF"
        fi
        ;;
      whiteip)
        if edge_ready; then
            netlog_edge whiteip 1 WHITEIP_UP WHITEIP_DOWN "Белый IP OK" "Белый IP недоступен" \
                iface="${WHITE_IF:-$WAN_IF}" ip="${WHITE_IP:-}"
            vpn_fail_streak=0
        else
            netlog_edge whiteip 0 WHITEIP_UP WHITEIP_DOWN "Белый IP OK" "Белый IP недоступен" \
                iface="${WHITE_IF:-$WAN_IF}" ip="${WHITE_IP:-}"
        fi
        ;;
      none|*)
        ;;
    esac

    # Жёсткий отказ WAN (link down / тестовый hold) — без ожидания cooldown
    wan_hard_down=0
    wan_oper="$(cat /sys/class/net/${WAN_IF}/operstate 2>/dev/null || echo down)"
    if [[ "$wan_oper" != "up" ]] || [[ -f /tmp/hold-wan-down ]]; then
        wan_hard_down=1
    fi

    if [[ $wan_up -eq 1 || $lte_up -eq 1 ]]; then
        netlog_edge no_uplink 0 NO_UPLINK NO_UPLINK_CLEAR \
            "Нет рабочего WAN и LTE" "Uplink снова есть"
    fi

    if [[ $wan_up -eq 1 ]]; then
        if [[ "$current_path" != "wan" ]] && can_switch && [[ $wan_ok_streak -ge $RECOVER_THRESHOLD ]]; then
            gw="$(get_gateway "$WAN_IF")"
            if [[ -n "$gw" ]]; then
                set_wan_route "$gw"
            else
                log "WAN online, gateway не найден"
                netlog WAN_NO_GW "WAN без gateway" iface="$WAN_IF"
            fi
        fi
        maybe_restart_edge
    elif [[ $lte_up -eq 1 ]]; then
        if [[ "$current_path" != "lte" ]] && { can_switch || [[ $wan_hard_down -eq 1 ]]; }; then
            set_lte_route
        elif [[ "$current_path" == "wan" ]] && ! ip route show default 2>/dev/null | grep -q " dev ${WAN_IF} "; then
            # Kernel уже снял WAN default (carrier loss) — синхронизируем path/метрики
            set_lte_route
        fi
        maybe_restart_edge
    else
        # Оба uplink плохие
        netlog_edge no_uplink 1 NO_UPLINK NO_UPLINK_CLEAR \
            "Нет рабочего WAN и LTE" "Uplink снова есть" \
            wan_fail="$wan_fail_streak" lte_fail="$lte_fail_streak"
        if [[ $lte_fail_streak -ge $FAIL_THRESHOLD ]]; then
            restart_lte_stack_bg || true
            lte_fail_streak=0
        fi
        # WAN force только если LTE уже тоже долго мёртв (не мешать dial-up LTE на boot)
        if [[ ! -f /tmp/hold-wan-down ]] && [[ "$wan_oper" != "up" ]] \
          && [[ $lte_fail_streak -ge $FAIL_THRESHOLD ]]; then
            ip link set "$WAN_IF" up 2>/dev/null || true
            networkctl up "$WAN_IF" 2>/dev/null || true
            netlog_edge wan_force 1 WAN_FORCE_UP WAN_FORCE_IDLE \
                "Принудительно поднят WAN link" "WAN force idle" iface="$WAN_IF"
        fi
    fi

    if [[ "$current_path" == "lte" || "$current_path" == "unknown" ]]; then
        if [[ $lte_up -eq 0 ]] && [[ $lte_fail_streak -ge $FAIL_THRESHOLD ]]; then
            restart_lte_stack_bg || true
            lte_fail_streak=0
        fi
    fi

    save_state "${current_path:-unknown}"
    sleep "$CHECK_INTERVAL"
done
