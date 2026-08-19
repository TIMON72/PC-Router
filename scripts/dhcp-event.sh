#!/usr/bin/env bash
# События DHCP от dnsmasq: add|old|del mac ip hostname
set -u
# shellcheck disable=SC1091
: "${SYSTEMA_ROUTER_ROOT:=/home/admin/PC-Router}"
source "$SYSTEMA_ROUTER_ROOT/scripts/lib/load-config.sh"
type netlog >/dev/null 2>&1 || netlog() { :; }
# shellcheck disable=SC1091

action="${1:-}"
mac="${2:-}"
ip="${3:-}"
hostname="${4:-*}"

case "$action" in
  add)
    netlog LAN_CLIENT_ADD "DHCP выдал адрес" mac="$mac" ip="$ip" host="$hostname" iface="${DNSMASQ_INTERFACE:-enp4s0}"
    ;;
  old)
    netlog LAN_CLIENT_RENEW "DHCP продлил аренду" mac="$mac" ip="$ip" host="$hostname"
    ;;
  del)
    netlog LAN_CLIENT_DEL "DHCP аренда снята" mac="$mac" ip="$ip" host="$hostname"
    ;;
  *)
    netlog LAN_DHCP_EVENT "DHCP событие" action="$action" mac="$mac" ip="$ip" host="$hostname"
    ;;
esac
exit 0
