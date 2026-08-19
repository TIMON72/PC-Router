# Внешний доступ: VPN или белый IP

В `config.env` задаётся режим:

```bash
EDGE_MODE=vpn       # OpenVPN (типичный вариант для площадок без белого IP)
# EDGE_MODE=whiteip # публичный IP на WAN / WHITE_IF
# EDGE_MODE=none    # только NAT + failover, без edge-мониторинга и DNAT
```

Проброс портов (`DEVICE_FORWARDS`) вешается на **edge-интерфейс**:

| `EDGE_MODE` | Куда вешается DNAT |
|-------------|--------------------|
| `vpn` | `VPN_IF` (обычно `tun0`) |
| `whiteip` | `WHITE_IF` или `WAN_IF` |
| `none` | проброс не создаётся |

Как зарезервировать IP устройству и пробросить порт: [lan-devices.md](lan-devices.md).

## VPN

См. [openvpn.md](openvpn.md).

Проверка «edge OK»: IPv4 на `VPN_IF`, опционально `VPN_PING_HOST`.  
При смене WAN↔LTE failover перезапускает `OPENVPN_UNIT`.

## Белый IP

```bash
EDGE_MODE=whiteip
# WHITE_IF=enp3s0           # по умолчанию = WAN_IF
# WHITE_IP=203.0.113.10     # если задан — должен быть на интерфейсе
# WHITE_PING_HOST=8.8.8.8   # опциональный контрольный пинг
```

OpenVPN не обязателен и не рестартуется.  
На чистом LTE белый IP на WAN снаружи обычно недоступен — это ожидаемо; failover всё равно поднимает интернет через LTE для LAN.

## none

Нет мониторинга туннеля/белого IP и нет DNAT из `DEVICE_FORWARDS`.  
Подходит, если площадка только раздаёт интернет в LAN.
