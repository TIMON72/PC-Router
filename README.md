# PC-Router

Превращает обычный ПК (mini-PC / NUC) с Ubuntu в **площадочный роутер**:

- раздаёт LAN (DHCP + NAT);
- держит интернет с **WAN (кабель)** и запасным **LTE (USB-модем)**;
- автоматически переключается WAN ↔ LTE;
- даёт удалённый доступ к устройствам за роутером через **OpenVPN** или **белый IP**.

```
Интернет ──► WAN (ethernet) ─┐
                              ├─► PC-Router ──► LAN (устройства)
LTE-модем ─► ppp0 ───────────┘        │
                                      ▼
                         edge: OpenVPN (tun) или белый IP
```

## Документация

| Документ | О чём |
|----------|--------|
| **[docs/INSTALL.md](docs/INSTALL.md)** | Полная установка: от Ubuntu до рабочей площадки |
| [docs/lan-devices.md](docs/lan-devices.md) | Фиксация IP по MAC и проброс портов через VPN |
| [docs/edge-access.md](docs/edge-access.md) | Режимы `vpn` / `whiteip` / `none` |
| [docs/openvpn.md](docs/openvpn.md) | Клиент OpenVPN |
| [tests/README.md](tests/README.md) | Диагностика и сценарии failover |

## Что нужно по железу

- ПК с Ubuntu Server (systemd + networkd)
- **2× Ethernet**: WAN и LAN (имена вроде `enp3s0` / `enp4s0` — смотрите `ip -br link`)
- Опционально: USB LTE-модем
- Учётка с `sudo` (в примерах: `admin`)

## Быстрый старт

На уже установленном Ubuntu с настроенным PPP-пиром `lte`:

```bash
sudo mkdir -p /home/admin
sudo chown admin:admin /home/admin
# клонируйте/скопируйте репозиторий:
cd /home/admin/PC-Router

cp config.env.example config.env
nano config.env                 # интерфейсы, EDGE_MODE, LAN, устройства

sudo bash scripts/install-deps.sh
sudo bash scripts/upgrade-failover.sh
sudo bash scripts/verify.sh
```

Подробности и OpenVPN — в [docs/INSTALL.md](docs/INSTALL.md).

## Конфиг площадки

Единственный рабочий файл: **`config.env`** в каталоге проекта  
(на устройстве обычно `/home/admin/PC-Router/config.env`).

- Образец с пояснениями: [`config.env.example`](config.env.example)
- Обновление кода **не затирает** `config.env`

## Зависимости

Список в [`requirements.txt`](requirements.txt):

```bash
sudo bash scripts/install-deps.sh      # apt на роутере
bash scripts/install-deps.sh --pip     # опционально: remote-тесты с ПК
```

## Совместимость имён

Ранее проект назывался `systema-router`. Скрипты по-прежнему понимают переменную окружения `SYSTEMA_ROUTER_ROOT` и старые ключи `CAMERA_LEASES` / `CAMERA_FORWARDS` (если новые `DEVICE_*` пусты). Для новых установок используйте каталог **`/home/admin/PC-Router`** и ключи **`DEVICE_*`**.
