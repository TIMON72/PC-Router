# Установка PC-Router (ПК → площадочный роутер)

Целевой каталог на устройстве: **`/home/admin/PC-Router`**.  
Весь площадочный конфиг, state, логи и скрипты живут там.  
В `/etc` попадают только файлы, без которых ОС/пакеты не работают (systemd, dnsmasq, ppp, openvpn, netplan).

---

## 0. Требования

| Что | Зачем |
|-----|--------|
| Ubuntu Server | networkd + systemd |
| 2 Ethernet | WAN (в интернет) + LAN (к устройствам) |
| USB LTE-модем | резервный uplink (опционально, но рекомендуется) |
| Пользователь с sudo | в примерах: `admin` |

Узнайте имена интерфейсов:

```bash
ip -br link
```

Их нужно будет прописать в `config.env` (`WAN_IF`, `LAN_IF`).

---

## 1. Скопировать проект

```bash
sudo mkdir -p /home/admin
sudo chown admin:admin /home/admin
# git clone … /home/admin/PC-Router
# или rsync/scp дерева репозитория
cd /home/admin/PC-Router
```

Если ставите не в `/home/admin/PC-Router`, задайте корень явно:

```bash
export SYSTEMA_ROUTER_ROOT=/path/to/PC-Router
```

и используйте этот путь во всех командах ниже.

---

## 2. Зависимости ОС

```bash
cd /home/admin/PC-Router
sudo bash scripts/install-deps.sh
```

Список пакетов — в `requirements.txt` (строки `apt: …`).

---

## 3. Конфиг площадки

```bash
cp config.env.example config.env
nano config.env
```

Минимум проверить:

| Параметр | Смысл |
|----------|--------|
| `WAN_IF` / `LAN_IF` / `LTE_IF` | Имена интерфейсов |
| `LAN_ADDR` / `LAN_NET` / `DHCP_RANGE_*` | Подсеть LAN |
| `EDGE_MODE` | `vpn` \| `whiteip` \| `none` |
| `DEVICE_LEASES` | Опционально: статический DHCP по MAC |
| `DEVICE_FORWARDS` | Опционально: проброс портов с edge → LAN |
| `OPENVPN_UNIT` | При `EDGE_MODE=vpn` (обычно `openvpn@vpn.service`) |

Каждый параметр подробно описан в комментариях `config.env.example`.  
Устройства в LAN: [lan-devices.md](lan-devices.md).

---

## 4. Netplan (адреса на интерфейсах)

WAN обычно получает адрес по DHCP. LAN — статический адрес роутера.

Пример идеи (имена и MAC подставьте свои):

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp3s0:
      dhcp4: true
    enp4s0:
      addresses: [192.168.50.1/24]
      dhcp4: false
      optional: true
      ignore-carrier: true
```

```bash
sudo netplan apply
```

В примере выше для WAN тоже желателен `optional: true` (cold boot без кабеля WAN / только LTE).  
`upgrade-failover.sh` гарантирует `optional: true` для WAN и `optional` / `ignore-carrier` для LAN.

---

## 5. PPP (LTE)

Пир **обязан** лежать здесь (так вызывает `pppd call lte`):

```text
/etc/ppp/peers/lte
```

В нём — tty модема и chat-скрипт. Проверка после установки сервисов:

```bash
sudo ls -l /etc/ppp/peers/lte
sudo systemctl start lte
ping -I ppp0 -c 2 8.8.8.8
```

---

## 6. OpenVPN (если `EDGE_MODE=vpn`)

См. [openvpn.md](openvpn.md). Кратко:

```bash
sudo mv ~/ca.crt ~/pswd.dat ~/vpn.conf /etc/openvpn/
sudo chmod 600 /etc/openvpn/pswd.dat
# в /etc/default/openvpn:
#   AUTOSTART="vpn"
sudo systemctl enable openvpn openvpn@vpn
sudo systemctl start openvpn@vpn
```

В `vpn.conf` предпочтительно абсолютный путь:

```text
auth-user-pass /etc/openvpn/pswd.dat
```

---

## 7. Белый IP (если `EDGE_MODE=whiteip`)

```bash
EDGE_MODE=whiteip
# WHITE_IF=enp3s0
# WHITE_IP=x.x.x.x
```

OpenVPN не нужен. WAN должен получать публичный адрес.

---

## 8. Установка сервисов PC-Router

```bash
cd /home/admin/PC-Router
sudo bash scripts/upgrade-failover.sh
sudo bash scripts/verify.sh
```

Скрипт ставит systemd unit’ы, хуки ppp/networkd, dnsmasq, NAT и плановую перезагрузку (если задана в `config.env`).

### Плановая перезагрузка

```bash
REBOOT_SCHEDULE_KIND=weekly    # daily | weekly | monthly | пусто = выкл
REBOOT_SCHEDULE_TIME=04:00
REBOOT_SCHEDULE_DAY=Sun
```

```bash
systemctl list-timers systema-scheduled-reboot.timer --no-pager
```

---

## 9. Проверка

```bash
sudo bash /home/admin/PC-Router/scripts/verify.sh
ip -br a
ip route
systemctl is-active lte lte-failover dnsmasq network-failsafe.timer
# при vpn:
systemctl is-active openvpn@vpn
ip -br a show tun0
ping -I ppp0 -c 2 8.8.8.8
sudo bash /home/admin/PC-Router/scripts/netlog-show.sh 50
```

Ожидаемо:

- default через WAN (или через LTE, если кабеля нет);
- LAN-адрес на `LAN_IF`;
- при VPN — интерфейс `tun0` с адресом площадки.

### LTE recovery (если PPP «молчит», а WiFi модема жив)

Failover поднимает LTE по лестнице, а не сразу крутит весь список APN:

1. PPP restart с тем же APN  
2. `AT+CFUN` (radio bounce)  
3. USB reset устройства  
4. APN next (медленно, с `APN_NEXT_COOLDOWN_SEC`)  
5. Перед outage-reboot failsafe ещё раз делает USB reset и отменяет reboot, если интернет ожил  

Широкий APN-перебор включается, если нет `state/apn.last` или USB-модем извлекали/вставляли (типичная смена SIM).

---

## 10. Обновление кода на уже работающей площадке

На устройстве (локально):

```bash
# config.env и state/ не затирать
cd /home/admin/PC-Router
sudo bash scripts/upgrade-failover.sh
```

С рабочей станции (модуль `deploy/`; `config.env` площадки на устройстве не перезаписывается):

`upgrade-failover.sh` при `EDGE_MODE=vpn` делает постоянный `systemctl enable openvpn@vpn` (не только runtime).

```powershell
copy deploy\config.env.example deploy\config.env
# указать PASS в секции целевого устройства
python -m deploy pc-62 push
```

Подробнее: [`deploy/README.md`](../deploy/README.md).

---

## 11. Где что лежит

### В проекте (`/home/admin/PC-Router`)

| Путь | Назначение |
|------|------------|
| `config.env` | Конфигурация площадки |
| `state/` | APN last, outage state, usb.generation |
| `conf/apn-profiles.conf` | База APN |
| `scripts/` | Failover, NAT, DHCP |
| `logs.log`, `lte-failover.log` | Журналы runtime |
| `tests/` | Диагностика и сценарии на устройстве |
| `deploy/` | CLI выкладки и удалённых тестов (с ПК) |
| `systemd/` | Шаблоны unit (копируются в `/etc`) |

### Только в системе

| Путь | Почему |
|------|--------|
| `/etc/systemd/system/lte*.service`, `network-failsafe.*` | unit systemd |
| `/etc/dnsmasq.d/50-pc-router-lan.conf` | DHCP/LAN |
| `/etc/ppp/peers/lte` | `pppd call lte` |
| `/etc/ppp/ip-up.d/systema-router` | хук pppd (имя историческое) |
| `/etc/openvpn/*` | при `EDGE_MODE=vpn` |
| `/etc/netplan/*.yaml` | адреса интерфейсов |
| netfilter-persistent | сохранённый NAT |

---

## 12. Тесты

Полное описание: [`tests/README.md`](../tests/README.md).

На устройстве:

```bash
sudo bash /home/admin/PC-Router/tests/run.sh list
sudo bash /home/admin/PC-Router/tests/run.sh snap
sudo bash /home/admin/PC-Router/tests/run.sh wan-failover 120 40
sudo bash /home/admin/PC-Router/tests/run.sh outage-dry
```

С рабочей станции:

```powershell
python -m deploy pc-62 test --all 1h
python -m deploy pc-62 status
python -m deploy pc-62 diag snap
```

Журнал удалённых прогонов: `tests/tests.log`.

---

## 13. Чеклист новой железки

1. Ubuntu + пользователь `admin`  
2. Скопировать репозиторий в `/home/admin/PC-Router`  
3. `sudo bash scripts/install-deps.sh`  
4. Netplan: WAN DHCP, LAN static  
5. `cp config.env.example config.env` → заполнить  
6. `/etc/ppp/peers/lte`  
7. При VPN — файлы в `/etc/openvpn/` + `AUTOSTART`  
8. `sudo bash scripts/upgrade-failover.sh`  
9. `sudo bash scripts/verify.sh`  
10. Проверить WAN / LTE / VPN / устройства в LAN  

Дальше: [lan-devices.md](lan-devices.md), [edge-access.md](edge-access.md).
