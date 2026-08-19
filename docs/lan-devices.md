# Устройства в LAN: IP по MAC и проброс через VPN

PC-Router раздаёт адреса в LAN (по умолчанию `192.168.50.0/24`) через **dnsmasq**.  
Любое устройство (камера, контроллер, ПК, NVR и т.д.) можно:

1. **зафиксировать IP** по MAC-адресу;
2. **пробросить порт** с внешнего edge (обычно OpenVPN) на это устройство.

Все настройки — в `config.env` площадки. Примеры ниже обобщённые, без привязки к конкретной модели.

---

## 1. Узнать MAC и желаемый IP

На роутере после того, как устройство подключилось к LAN:

```bash
cat /var/lib/misc/dnsmasq.leases
# или
ip neigh show dev enp4s0
```

Выберите свободный IP **вне** DHCP-диапазона *или* внутри него — dnsmasq отдаст reservation с высшим приоритетом. Удобная схема:

| Диапазон | Назначение |
|----------|------------|
| `.1` | сам роутер (`LAN_ADDR`) |
| `.10–.100` | обычный DHCP |
| `.101+` | статически зарезервированные устройства |

---

## 2. Зафиксировать IP за MAC (`DEVICE_LEASES`)

Формат (несколько устройств через `;`, строку — в **кавычках**):

```bash
DEVICE_LEASES='aa:bb:cc:dd:ee:01,192.168.50.101,gate-reader;aa:bb:cc:dd:ee:02,192.168.50.102,office-cam'
```

Поля: `MAC,IP,HOSTNAME` (hostname опционален: `MAC,IP`).

Применить:

```bash
cd /home/admin/PC-Router
sudo bash scripts/upgrade-failover.sh
# или точечно:
sudo bash scripts/write-dnsmasq-cameras.sh
sudo systemctl restart dnsmasq
```

Проверка:

```bash
grep dhcp-host /etc/dnsmasq.d/50-pc-router-lan.conf
ping -c 1 192.168.50.101
```

> Совместимость: если задан только старый ключ `CAMERA_LEASES`, он всё ещё используется.

---

## 3. Проброс порта с VPN на устройство (`DEVICE_FORWARDS`)

Нужен `EDGE_MODE=vpn` (или `whiteip`). Проброс вешается на **edge-интерфейс** (`tun0` / WAN), не на LAN.

Формат: `EDGE_PORT:LAN_IP:LAN_PORT` через `;`:

```bash
DEVICE_FORWARDS='8001:192.168.50.101:80;8002:192.168.50.102:443'
```

Смысл: с машины в корпоративной сети / VPN открываете `http://<VPN-IP-площадки>:8001` → попадаете на `192.168.50.101:80` за роутером.

Применить:

```bash
sudo bash /home/admin/PC-Router/scripts/apply-nat-rules.sh
# или полный upgrade-failover.sh
sudo netfilter-persistent save   # если пакет установлен
```

Проверка с хоста внутри VPN:

```bash
curl -I http://10.x.x.x:8001
```

> Совместимость: старый ключ `CAMERA_FORWARDS` ещё читается.

Подробнее про режимы edge: [edge-access.md](edge-access.md).

---

## 4. Типовой сценарий «устройство доступно по VPN»

1. Устройство в LAN, получает/резервирует IP (`DEVICE_LEASES`).  
2. На роутере поднят OpenVPN (`tun0`), известен адрес площадки в VPN.  
3. В `DEVICE_FORWARDS` добавлен порт.  
4. С рабочей станции в той же VPN-сети: `VPN_IP:EDGE_PORT` → сервис на устройстве.  

Firewall на самом устройстве (если есть) должен принимать трафик с LAN/роутера.
