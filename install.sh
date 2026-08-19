#!/usr/bin/env bash
# Первичная установка: зависимости + upgrade из текущего дерева.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SYSTEMA_ROUTER_ROOT:-${PC_ROUTER_ROOT:-/home/admin/PC-Router}}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите: sudo bash install.sh" >&2
  exit 1
fi

echo "==> apt"
bash "$ROOT_DIR/scripts/install-deps.sh"

echo "==> проект → $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
if [[ "$(realpath "$ROOT_DIR")" != "$(realpath "$PROJECT_DIR")" ]]; then
  rsync -a --exclude '.git' "$ROOT_DIR"/ "$PROJECT_DIR"/
fi
if [[ ! -f "$PROJECT_DIR/config.env" ]]; then
  if [[ -f "$ROOT_DIR/config.env" ]]; then
    cp -a "$ROOT_DIR/config.env" "$PROJECT_DIR/config.env"
  else
    cp -a "$ROOT_DIR/config.env.example" "$PROJECT_DIR/config.env"
    echo "Создан $PROJECT_DIR/config.env из example — отредактируйте и повторите upgrade."
  fi
fi
chown -R admin:admin "$PROJECT_DIR" 2>/dev/null || true

# shellcheck disable=SC1090
source "$PROJECT_DIR/config.env"
WAN_IF="${WAN_IF:-enp3s0}"
LAN_IF="${LAN_IF:-enp4s0}"
LAN_CIDR="${LAN_CIDR:-192.168.50.1/24}"

echo "==> netplan $WAN_IF DHCP, $LAN_IF $LAN_CIDR"
cat >/etc/netplan/50-systema-router.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${WAN_IF}:
      dhcp4: true
      optional: true
    ${LAN_IF}:
      dhcp4: false
      addresses:
        - ${LAN_CIDR}
      optional: true
      ignore-carrier: true
EOF
chmod 600 /etc/netplan/50-systema-router.yaml
netplan apply || true

echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-router.conf
sysctl -p /etc/sysctl.d/99-router.conf

export SYSTEMA_ROUTER_ROOT="$PROJECT_DIR"
bash "$PROJECT_DIR/scripts/upgrade-failover.sh"

EDGE_MODE="${EDGE_MODE:-vpn}"
OPENVPN_UNIT="${OPENVPN_UNIT:-openvpn@vpn.service}"
if [[ "$EDGE_MODE" == "vpn" ]] && systemctl list-unit-files | grep -F "${OPENVPN_UNIT%.service}" >/dev/null 2>&1; then
  systemctl enable "$OPENVPN_UNIT" || true
fi

echo "Готово. Дальше: docs/INSTALL.md §8"
bash "$PROJECT_DIR/scripts/verify.sh" || true
