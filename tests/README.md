# Тесты PC-Router

Каталог `tests/` содержит диагностику и сценарии, выполняемые **на устройстве**.  
Удалённая заливка кода и запуск с рабочей станции выполняются модулем `deploy/` (см. раздел ниже и [`deploy/`](../deploy/)).

## Структура

| Путь | Назначение |
|------|------------|
| `run.sh` | Точка входа на устройстве: `sudo bash tests/run.sh <команда> [args…]` |
| `lib/common.sh` | Общие хелперы (snapshot, test.env, cleanup) |
| `diag/` | Снимки состояния, unit-проверки recovery |
| `scenarios/` | Интеграционные сценарии failover / LTE / outage |
| `fixtures/` | Ускоренные параметры (`test.env`) для прогонов |
| `tests.log` | Лог удалённых прогонов с ПК (append; в `.gitignore`) |

## Правила

1. Каждый сценарий обязан завершать cleanup (`trap EXIT`): не оставлять `hold-wan-down` и `/run/systema-router/test.env`.
2. Ускорение прогонов — через `/run/systema-router/test.env`. В тестах по умолчанию `REBOOT_DRY_RUN=1` (реальный reboot ОС запрещён).
3. Учётные данные SSH и перечень устройств хранятся в `deploy/config.env`, не в `tests/`.
4. Корневой `config.env` — конфигурация **площадки на роутере**. Файл `deploy/config.env` — конфигурация **ПК** (хост, логин, пароль, `DEVICE_NAME`).

## Запуск на устройстве

```bash
cd ~/PC-Router
sudo bash tests/run.sh list
sudo bash tests/run.sh snap
sudo bash tests/run.sh recover-selftest
sudo bash tests/run.sh wan-failover 120 40
sudo bash tests/run.sh lte-soft-fail
sudo bash tests/run.sh lte-recover-ladder 180
sudo bash tests/run.sh lte-apn-firstboot 150
sudo bash tests/run.sh outage-dry
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
| `python -m deploy <device> test --all <duration>` | Полный набор сценариев в течение заданного интервала |
| `python -m deploy <device> test <scenario> [-- args…]` | Один сценарий / diag-команда |

Примеры:

```powershell
python -m deploy pc-62 push
python -m deploy pc-62 test --all 1h
python -m deploy pc-62 test snap
python -m deploy pc-62 test wan-failover -- 120 40
```

### Длительность `test --all`

Параметр `<duration>` обязателен. Технический минимум — **300 с**, но для **полного** набора сценариев без ужимания окон нужно около **40 минут**; практический ориентир — **`1h`** (и дольше для повторных кругов).

Допустимы число секунд либо пресеты (шкала согласована с `REBOOT_SCHEDULE_SEC`, дополнительно `8h`):

| Значение | Секунды | Замечание |
|----------|----------|-----------|
| `300`, `5m` | 300 | только smoke; окна наблюдения сильно сокращаются |
| `1h`, `3600` | 3600 | рекомендуется для полного прогона |
| `2h`, `7200` | 7200 | |
| `4h`, `14400` | 14400 | |
| `6h`, `21600` | 21600 | |
| `8h`, `28800` | 28800 | |
| `12h`, `43200` | 43200 | |
| `24h`, `1d`, `86400` | 86400 | |

В течение указанного интервала сценарии выполняются циклически. Если бюджет меньше ~40 мин, окна наблюдения внутри сценариев пропорционально сокращаются (риск ложных FAIL, как у `outage-dry`).

### Журналирование

Весь вывод удалённых команд `test` (кроме полного dump сценариев в `--all`) дублируется в консоль и в **`tests/tests.log`** (append; в `.gitignore`).  
Режим `test --all` пишет краткие строки `[n/N] scenario … PASS|FAIL` и сводку; детальный отчёт — `tmp/suite-<device>-report.json` / `.md`.
