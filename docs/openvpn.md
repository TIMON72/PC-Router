# OpenVPN на PC-Router

Для площадок с белым IP вместо VPN см. [edge-access.md](edge-access.md) (`EDGE_MODE=whiteip`).

Имя профиля задаёт unit systemd: файл `/etc/openvpn/vpn.conf` → сервис `openvpn@vpn`  
(в `config.env`: `EDGE_MODE=vpn`, `OPENVPN_UNIT=openvpn@vpn.service`). При другом имени файла поправьте и unit.

## 1. Пакет

```bash
openvpn --version
# если нет:
sudo bash scripts/install-deps.sh
```

## 2. Файлы профиля

| Файл | Назначение |
|------|------------|
| `vpn.conf` | клиентский конфиг OpenVPN |
| `ca.crt` | CA-сертификат |
| `pswd.dat` | логин/пароль (auth-user-pass), обычно 2 строки |

В `vpn.conf` предпочтительно:

```text
ca /etc/openvpn/ca.crt
auth-user-pass /etc/openvpn/pswd.dat
```

## 3. Установка в `/etc/openvpn`

```bash
sudo mv ~/ca.crt /etc/openvpn/
sudo mv ~/pswd.dat /etc/openvpn/
sudo mv ~/vpn.conf /etc/openvpn/
sudo chmod 600 /etc/openvpn/pswd.dat
```

## 4. Автозапуск

В `/etc/default/openvpn`:

```text
AUTOSTART="vpn"
```

(`vpn` = имя файла без `.conf`.)

```bash
sudo systemctl enable openvpn
sudo systemctl enable openvpn@vpn
sudo systemctl start openvpn@vpn
systemctl status openvpn@vpn --no-pager
ip -br a show tun0
```

## 5. Связь с PC-Router

- В `config.env`: `EDGE_MODE=vpn`.
- Failover рестартует unit из `OPENVPN_UNIT` при смене WAN↔LTE.
- Проброс портов — `DEVICE_FORWARDS` на `VPN_IF` (см. [lan-devices.md](lan-devices.md)).

После смены uplink или VPN:

```bash
sudo systemctl restart openvpn@vpn
sudo bash /home/admin/PC-Router/scripts/apply-nat-rules.sh
```
