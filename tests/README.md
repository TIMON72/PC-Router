# Тесты PC-Router

Каталог `tests/` содержит диагностику и сценарии, выполняемые **на устройстве**.  
Удалённая заливка кода и запуск с рабочей станции выполняются модулем `deploy/` (см. раздел ниже и [`deploy/`](../deploy/)).

## Структура

| Путь | Назначение |
|------|------------|
| `run.sh` | Точка входа на устройстве: `sudo bash tests/run.sh <команда> [args…]` |
| `lib/common.sh` | Общие хелперы (snapshot, test.env, cleanup) |
| `diag/` | Снимки состояния, unit-проверки recovery, **status** (сервисный отчёт) |
| `scenarios/` | Интеграционные сценарии failover / LTE / outage |
| `fixtures/` | Ускоренные параметры (`test.env`) для прогонов |
| `tests.log` | Лог удалённых прогонов с ПК (append; в `.gitignore`) |

## Правила

1. Каждый сценарий обязан завершать cleanup (`trap EXIT`): не оставлять `hold-wan-down` и `/run/systema-router/test.env`.
2. Ускорение прогонов — через `/run/systema-router/test.env`. В outage-тестах по умолчанию `REBOOT_DRY_RUN=1`. Сценарии `reboot-*` делают реальный reboot.
3. **SKIP (exit 77)**: если до старта нет нужного uplink (кабель WAN вынут / нет LTE-модема) — сценарий пропускается, suite идёт дальше и **не считает SKIP провалом**.  
   Mid-test: оператор выдернул интерфейс (не hold теста) → по умолчанию **FAIL**; для ручных экспериментов `TEST_MID_DISCONNECT=skip` → SKIP.  
   В `lte-recover-ladder` / `lte-apn-firstboot` mid-check не стоит — там USB reseat сам по себе роняет железо.
4. Учётные данные SSH и перечень устройств хранятся в `deploy/config.env`, не в `tests/`.
5. Корневой `config.env` — конфигурация **площадки на роутере**. Файл `deploy/config.env` — конфигурация **ПК** (хост, логин, пароль, `DEVICE_NAME`).

## Запуск на устройстве

```bash
cd ~/PC-Router
sudo bash tests/run.sh list
sudo bash tests/run.sh snap
sudo bash tests/run.sh status        # сервисный отчёт (по умолчанию 1 день; сводка + события за окно)
sudo bash tests/run.sh status 14     # то же за 14 дней
sudo bash tests/run.sh dhcp-lan
sudo bash tests/run.sh recover-selftest
sudo bash tests/run.sh wan-failover 120 40
sudo bash tests/run.sh vpn-lte-boot 150
sudo bash tests/run.sh reboot-wan 180
sudo bash tests/run.sh reboot-lte 180
sudo bash tests/run.sh reboot-both 180
sudo bash tests/run.sh lte-soft-fail
sudo bash tests/run.sh lte-recover-ladder 180
sudo bash tests/run.sh lte-apn-firstboot 150
sudo bash tests/run.sh outage-dry
sudo bash tests/run.sh boot-timeline 40
```

Аргументы длительности (секунды) зависят от сценария; см. `tests/run.sh help`.

## Удалённый запуск с ПК (`deploy/`)

### Подготовка

```powershell
copy deploy\config.env.example deploy\config.env
```

Заполните `PASS` (и при необходимости `HOST` / `USER`) в секции активного устройства.  
Идентификатор устройства в CLI: `DEVICE_NAME` (например `pc-62`), идентификатор секции (`62`) или IP.

### Команды

| Команда | Описание |
|---------|----------|
| `python -m deploy list` | Список устройств из `deploy/config.env` |
| `python -m deploy <device> push` | Залить дерево проекта и выполнить `upgrade-failover.sh` (локальный `config.env` площадки не перезаписывается) |
| `python -m deploy <device> status [days]` | Сервисный отчёт (по умолчанию **1** день; `status -- 14` — за 14 дней) |
| `python -m deploy <device> diag <cmd> [-- args…]` | Любая diag-команда: `snap`, `dhcp-lan`, `events`, … |
| `python -m deploy <device> test --all <duration>` | Полный набор сценариев в течение заданного интервала |
| `python -m deploy <device> test <scenario> [-- args…]` | Один интеграционный сценарий |

Примеры:

```powershell
python -m deploy pc-62 push
python -m deploy pc-62 test --all 1h
python -m deploy pc-62 status          # за 1 день (по умолчанию)
python -m deploy pc-62 status -- 14    # за 14 дней
python -m deploy pc-62 diag snap
python -m deploy pc-62 diag dhcp-lan
python -m deploy pc-62 test wan-failover -- 120 40
python -m deploy pc-62 test vpn-lte-boot -- 150
python -m deploy pc-62 test reboot-lte -- 180
```

### Состав `test --all`

Порядок одного круга (`deploy/tests.py` → `_SUITE`), **сгруппировано по uplink** (в логе — заголовки секций):

| Uplink | Сценарии | Когда можно выдернуть |
|--------|----------|------------------------|
| unit | `recover-selftest` | — |
| **LAN** | `dhcp-lan` | без WAN/LTE; dnsmasq + число клиентов |
| WAN\|LTE | `outage-dry` | нужен хотя бы один |
| **WAN+LTE** | `wan-failover`, `reboot-both` | **оба** — не трогать |
| **WAN** | `reboot-wan` | LTE можно отключить |
| **LTE** | `vpn-lte-boot`, `reboot-lte`, `lte-soft-fail`, `lte-recover-ladder`, `lte-apn-firstboot` | WAN можно отключить |

| Сценарий | Что проверяет |
|----------|----------------|
| `recover-selftest` | unit recovery-lib без железа |
| `dhcp-lan` | dnsmasq active, LAN-адрес, число DHCP-leases / neigh |
| `outage-dry` | эскалация outage → REBOOT_DRY |
| `wan-failover` | WAN↓ → LTE + VPN, возврат WAN |
| `reboot-both` | **reboot**, WAN+LTE → приоритет WAN + VPN |
| `reboot-wan` | **reboot**, только WAN → path=wan + VPN |
| `vpn-lte-boot` | VPN убит при LTE-only → сам поднимается |
| `reboot-lte` | **reboot**, только LTE (WAN hold) → path=lte + VPN |
| `lte-soft-fail` | soft-fail LTE |
| `lte-recover-ladder` | лестница recovery PPP→CFUN→USB→APN |
| `lte-apn-firstboot` | firstboot без `apn.last` |

Reboot-сценарии пишут итог в `state/reboot-test.result` (не `/tmp`: после reboot tmpfs пустой). На круг — три полных перезагрузки ОС.

### Длительность `test --all`

Параметр `<duration>` обязателен. Минимум — **1h**. Полный круг без ужимания окон — около **70–80 минут** (в т.ч. 3× reboot); ориентир — **`2h`**.

| Значение | Секунды | Замечание |
|----------|----------|-----------|
| `1h`, `3600` | 3600 | может ужать окна (особенно reboot) |
| `2h`, `7200` | 7200 | рекомендуется при полном наборе с reboot |
| `4h`, `14400` | 14400 | |
| `6h`, `21600` | 21600 | |
| `8h`, `28800` | 28800 | |
| `12h`, `43200` | 43200 | |
| `24h`, `1d`, `86400` | 86400 | |

В течение указанного интервала сценарии выполняются циклически. Если бюджет меньше ~70 мин, окна наблюдения внутри сценариев пропорционально сокращаются (риск ложных FAIL).

Reboot-сценарии в консоли идут как обычный прогресс (`[n/N] reboot-lte ... PASS`); ожидаемый обрыв SSH при перезагрузке не логируется. Сообщение появляется только если устройство не вернулось за timeout или verify FAIL.

### Журналирование

Весь вывод удалённых команд `test` (кроме полного dump сценариев в `--all`) дублируется в консоль и в **`tests/tests.log`** (append; в `.gitignore`).  
Режим `test --all` пишет краткие строки `[n/N] scenario … PASS|FAIL` и сводку; детальный отчёт — `tmp/suite-<device>-report.json` / `.md`.
