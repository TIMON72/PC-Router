#!/usr/bin/env bash
# Установка/обновление PC-Router из каталога проекта.
# Источник истины: $PROJECT_DIR (по умолчанию /home/admin/PC-Router).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="${SYSTEMA_ROUTER_ROOT:-${PC_ROUTER_ROOT:-/home/admin/PC-Router}}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите: sudo bash scripts/upgrade-failover.sh" >&2
  exit 1
fi

# Синхронизация дерева в PROJECT_DIR (не трогаем площадочные данные)
if [[ "$(realpath "$ROOT_DIR")" != "$(realpath "$PROJECT_DIR")" ]]; then
  mkdir -p "$PROJECT_DIR"
  rsync -a --exclude '.git' --exclude 'state' --exclude 'config.env' \
    --exclude 'logs.log' --exclude 'lte-failover.log' \
    "$ROOT_DIR"/ "$PROJECT_DIR"/
fi

install -d -m 0755 \
  "$PROJECT_DIR" "$PROJECT_DIR/state" "$PROJECT_DIR/conf" \
  /run/systema-router \
  /etc/ppp/ip-up.d \
  /etc/networkd-dispatcher/carrier.d \
  /etc/networkd-dispatcher/routable.d \
  /etc/dnsmasq.d \
  /etc/systemd/system/dnsmasq.service.d \
  /etc/systemd/system/openvpn@vpn.service.d

# Миграция со старых путей (один раз), затем удаление legacy
if [[ -e /etc/systema-router/config.env && ! -L /etc/systema-router/config.env ]]; then
  if [[ ! -f "$PROJECT_DIR/config.env" ]] \
    || ! grep -qE '^(DEVICE_LEASES|CAMERA_LEASES)=.+:.+' "$PROJECT_DIR/config.env" 2>/dev/null; then
    cp -a /etc/systema-router/config.env "$PROJECT_DIR/config.env"
    echo "migrated: /etc/systema-router/config.env → project"
  fi
fi
if [[ -f /etc/systema-router/apn.last && ! -L /etc/systema-router/apn.last \
  && ! -f "$PROJECT_DIR/state/apn.last" ]]; then
  cp -a /etc/systema-router/apn.last "$PROJECT_DIR/state/apn.last"
fi
if [[ -f /var/lib/systema-router/outage.state && ! -f "$PROJECT_DIR/state/outage.state" ]]; then
  cp -a /var/lib/systema-router/outage.state "$PROJECT_DIR/state/outage.state"
fi

if [[ ! -f "$PROJECT_DIR/config.env" ]]; then
  cp -a "$ROOT_DIR/config.env.example" "$PROJECT_DIR/config.env"
fi
if [[ "$(realpath -m "$ROOT_DIR/conf/apn-profiles.conf")" != "$(realpath -m "$PROJECT_DIR/conf/apn-profiles.conf")" ]]; then
  install -m 0644 "$ROOT_DIR/conf/apn-profiles.conf" "$PROJECT_DIR/conf/apn-profiles.conf"
fi

CFG="$PROJECT_DIR/config.env"
sed -i '/^LTE_APN=/d' "$CFG"
for kv in \
  "SYSTEMA_ROUTER_ROOT=$PROJECT_DIR" \
  "APN_PROFILES_FILE=$PROJECT_DIR/conf/apn-profiles.conf" \
  "APN_LAST_FILE=$PROJECT_DIR/state/apn.last" \
  "NETLOG_DIR=$PROJECT_DIR" \
  "NETLOG_FILE=$PROJECT_DIR/logs.log" \
  "LOG_FILE=$PROJECT_DIR/lte-failover.log" \
  "REBOOT_STATE_DIR=$PROJECT_DIR/state"
do
  key="${kv%%=*}"
  if grep -q "^${key}=" "$CFG"; then
    sed -i "s|^${key}=.*|${kv}|" "$CFG"
  else
    echo "$kv" >>"$CFG"
  fi
done
chown admin:admin "$CFG" 2>/dev/null || true
chmod 0755 "$PROJECT_DIR"/scripts/*.sh "$PROJECT_DIR"/scripts/lib/*.sh 2>/dev/null || true
chmod 0755 "$PROJECT_DIR"/tests/run.sh "$PROJECT_DIR"/tests/diag/*.sh "$PROJECT_DIR"/tests/scenarios/*.sh 2>/dev/null || true

export SYSTEMA_ROUTER_ROOT="$PROJECT_DIR"
export CONFIG_FILE="$CFG"

# --- Обязательные системные точки (иначе сервисы ОС не подхватят) ---
# systemd units → ExecStart из проекта (подстановка корня; старый путь тоже)
_subst_root() {
  sed -e "s|/home/admin/PC-Router|$PROJECT_DIR|g" \
      -e "s|/home/admin/systema-router|$PROJECT_DIR|g" "$1"
}
_subst_root "$ROOT_DIR/systemd/lte-failover.service" >/etc/systemd/system/lte-failover.service
_subst_root "$ROOT_DIR/systemd/lte.service" >/etc/systemd/system/lte.service
_subst_root "$ROOT_DIR/systemd/network-failsafe.service" >/etc/systemd/system/network-failsafe.service
install -m 0644 "$ROOT_DIR/systemd/network-failsafe.timer" /etc/systemd/system/network-failsafe.timer
_subst_root "$ROOT_DIR/systemd/dnsmasq.service.d/override.conf" \
  >/etc/systemd/system/dnsmasq.service.d/override.conf
install -m 0644 "$ROOT_DIR/systemd/openvpn-vpn.service.d/override.conf" \
  /etc/systemd/system/openvpn@vpn.service.d/override.conf
_subst_root "$ROOT_DIR/conf/logrotate-systema-router.conf" >/etc/logrotate.d/systema-router

# ppp / networkd: каталоги фиксированы пакетами
cat >/etc/ppp/ip-up.d/systema-router <<EOF
#!/bin/bash
export SYSTEMA_ROUTER_ROOT=$PROJECT_DIR
exec "\$SYSTEMA_ROUTER_ROOT/scripts/ppp-ip-up-systema.sh" "\$@"
EOF
chmod 0755 /etc/ppp/ip-up.d/systema-router

cat >/etc/networkd-dispatcher/carrier.d/50-systema-lan <<EOF
#!/bin/bash
export SYSTEMA_ROUTER_ROOT=$PROJECT_DIR
exec "\$SYSTEMA_ROUTER_ROOT/scripts/lan-carrier-hook.sh" "\$@"
EOF
chmod 0755 /etc/networkd-dispatcher/carrier.d/50-systema-lan
cp -a /etc/networkd-dispatcher/carrier.d/50-systema-lan \
  /etc/networkd-dispatcher/routable.d/50-systema-lan

# dnsmasq читает только /etc/dnsmasq.d
SYSTEMA_ROUTER_ROOT="$PROJECT_DIR" CONFIG_FILE="$CFG" \
  "$PROJECT_DIR/scripts/write-dnsmasq-cameras.sh"
cat >/etc/dnsmasq.d/60-systema-dhcp-log.conf <<EOF
dhcp-script=$PROJECT_DIR/scripts/dhcp-event.sh
EOF

if [[ -f /etc/dnsmasq.conf ]] && grep -qE '^(interface=enp4s0|dhcp-range=192\.168\.50)' /etc/dnsmasq.conf; then
  cp -a /etc/dnsmasq.conf "/etc/dnsmasq.conf.bak.$(date +%s)" || true
  sed -i -E \
    '/^interface=enp4s0/d;/^bind-interfaces/d;/^dhcp-authoritative/d;/^dhcp-range=/d;/^dhcp-option=/d;/^dhcp-host=/d;/^dhcp-leasefile=/d;/^dhcp-rapid-commit/d' \
    /etc/dnsmasq.conf
fi

# Логи
touch "$PROJECT_DIR/logs.log" "$PROJECT_DIR/lte-failover.log"
chmod 644 "$PROJECT_DIR/logs.log" "$PROJECT_DIR/lte-failover.log"
chown admin:admin "$PROJECT_DIR/logs.log" "$PROJECT_DIR/lte-failover.log" "$PROJECT_DIR/state" 2>/dev/null || true

# netplan: WAN optional (cold boot без кабеля) + LAN ignore-carrier
WAN_IF_NP="$(grep -E '^WAN_IF=' "$CFG" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\"' || true)"
WAN_IF_NP="${WAN_IF_NP:-enp3s0}"
LAN_IF_NP="$(grep -E '^LAN_IF=' "$CFG" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\"' || true)"
LAN_IF_NP="${LAN_IF_NP:-enp4s0}"
for f in /etc/netplan/*.yaml; do
  [[ -f "$f" ]] || continue
  python3 - "$f" "$WAN_IF_NP" "$LAN_IF_NP" <<'PY' 2>/dev/null || true
import sys, re
path, wan_if, lan_if = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
orig = text

def ensure_optional(iface: str, body: str) -> str:
    m = re.search(rf"({re.escape(iface)}:\n(?:[ \t]+.+\n)*)", body)
    if not m:
        return body
    block = m.group(1)
    if re.search(r"^[ \t]+optional:\s*true\s*$", block, re.M):
        return body
    block2 = block.rstrip("\n") + "\n      optional: true\n"
    return body[: m.start(1)] + block2 + body[m.end(1) :]

def ensure_lan_ignore(iface: str, body: str) -> str:
    m = re.search(rf"({re.escape(iface)}:\n(?:[ \t]+.+\n)*)", body)
    if not m:
        return body
    block = m.group(1)
    if "ignore-carrier:" in block:
        return body
    block2 = block.rstrip("\n") + "\n      optional: true\n      ignore-carrier: true\n"
    return body[: m.start(1)] + block2 + body[m.end(1) :]

text = ensure_optional(wan_if, text)
text = ensure_lan_ignore(lan_if, text)
if text != orig:
    open(path, "w", encoding="utf-8").write(text)
PY
done

find "$PROJECT_DIR" /etc/ppp/ip-up.d/systema-router \
  /etc/networkd-dispatcher/carrier.d/50-systema-lan \
  /etc/networkd-dispatcher/routable.d/50-systema-lan \
  /etc/systemd/system/lte.service \
  /etc/systemd/system/lte-failover.service \
  /etc/systemd/system/network-failsafe.service \
  /etc/systemd/system/network-failsafe.timer \
  -type f \( -name '*.sh' -o -name '*.service' -o -name '*.timer' -o -name 'systema-router' -o -name '50-systema-lan' \) \
  -exec sed -i 's/\r$//' {} + 2>/dev/null || true

SYSTEMA_ROUTER_ROOT="$PROJECT_DIR" CONFIG_FILE="$CFG" \
  "$PROJECT_DIR/scripts/apply-nat-rules.sh" || true
netfilter-persistent save 2>/dev/null || true

# Плановая перезагрузка по config.env
bash "$PROJECT_DIR/scripts/install-reboot-schedule.sh" || true

# Удалить legacy-копии (больше не используются)
rm -rf /etc/systema-router /var/lib/systema-router /usr/local/lib/systema-router
rm -f /usr/local/bin/lte-failover.sh /usr/local/bin/lte-modem-init.sh
rm -f /usr/local/sbin/lte-apn-select.sh /usr/local/sbin/apply-nat-rules.sh \
  /usr/local/sbin/systema-router-verify.sh /usr/local/sbin/wait-enp4s0-camera-lan.sh \
  /usr/local/sbin/write-dnsmasq-cameras.sh /usr/local/sbin/systema-dhcp-event.sh \
  /usr/local/sbin/network-failsafe.sh /usr/local/sbin/netlog-show.sh \
  /usr/local/sbin/safe-failover-test.sh

systemctl daemon-reload
systemctl enable lte.service lte-failover.service network-failsafe.timer dnsmasq.service
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/lib/load-config.sh"
if [[ "${EDGE_MODE:-vpn}" == "vpn" ]]; then
  OPENVPN_UNIT="${OPENVPN_UNIT:-openvpn@vpn.service}"
  # Instance openvpn@vpn не фигурирует в list-unit-files (только шаблон openvpn@.service).
  systemctl enable "$OPENVPN_UNIT" 2>/dev/null || true
  # Debian/Ubuntu: AUTOSTART профилей из /etc/default/openvpn
  systemctl enable openvpn.service 2>/dev/null || true
fi
systemctl restart lte-failover.service
systemctl restart dnsmasq.service || systemctl start dnsmasq.service || true
systemctl start network-failsafe.timer
systemctl restart network-failsafe.timer
netplan apply 2>/dev/null || true

echo "OK PROJECT=$PROJECT_DIR"
echo "CONFIG=$CFG"
echo "STATE=$PROJECT_DIR/state"
echo "LOG=$PROJECT_DIR/logs.log"
echo "verify: sudo $PROJECT_DIR/scripts/verify.sh"
echo "tests:  sudo bash $PROJECT_DIR/tests/run.sh list"
