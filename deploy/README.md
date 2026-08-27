# deploy — удалённое обновление и тесты

Модуль рабочей станции для выкладки PC-Router на устройства и запуска `tests/` по SSH.

## Состав

| Модуль | Роль |
|--------|--------|
| `remote.py` | SSH/SFTP, чтение `config.env`, выбор устройства |
| `push.py` | Заливка дерева роутера + `upgrade-failover.sh` (без `build/`, `deploy/`, секретов) |
| `tests.py` | Удалённый запуск: один сценарий или `test --all` |
| `log.py` | Дублирование вывода `test` в `tests/tests.log` |
| `__main__.py` | CLI `python -m deploy …` |

Сценарии лежат в `tests/` **на устройстве**; `deploy/tests.py` только оркестрирует их по SSH.

## Конфигурация

| Файл | Назначение |
|-------|------------|
| `config.env.example` | Образец (в репозитории) |
| `config.env` | Рабочий файл с секретами (в `.gitignore`) |

Формат: глобальный `ACTIVE=` (fallback) и секции устройств `[62]`, `[60]` с полями `DEVICE_NAME`, `HOST`, `USER`, `PASS`, `REMOTE_ROOT`.

Переменные окружения `SYSTEMA_*` / `SYSTEMA_ACTIVE` перекрывают значения из файла.

Корневой `config.env` проекта — конфигурация площадки на роутере; его не следует путать с `deploy/config.env`.

`push` заливает на устройство только runtime-дерево (`scripts/`, `tests/`, `systemd/`, …). **Не** отправляет: `build/`, `deploy/`, `dist/`, `tmp/`, venv, локальный `config.env`. Если эти каталоги уже лежат на роутере от старых push — **удаляются** при следующем `push` (кроме `tmp/` на устройстве: там отчёты suite).

## CLI

```text
python -m deploy list
python -m deploy <device> push
python -m deploy <device> test --all <duration>
python -m deploy <device> test <scenario> [-- args…]
```

`<device>` — `DEVICE_NAME`, id секции или `HOST`. Если опущен, используется `ACTIVE` из `deploy/config.env`.

`test --all` требует длительность. Минимум **1h**; полный круг без ужимания окон — около **70–80 мин** (включая 3 реальных reboot); ориентир — **`2h`**. Пресеты: `1h`, `2h`, `4h`, `6h`, `8h`, `12h`, `24h` (см. [`tests/README.md`](../tests/README.md)).

Журнал прогонов: `tests/tests.log` (из исходников) или `build/dist/tests.log` (рядом с exe).

## Полевой kit (Windows, без Python)

Готовый kit: [`build/dist/`](../build/dist/) (собирается скриптом в `build/`).

1. Соберите:
   ```powershell
   python -m build
   ```
2. Скопируйте **`build/dist/`** на USB (`pcrouter.exe` + `config.env` с заполненным `PASS`).
3. На объекте:
   ```text
   cd dist
   pcrouter.exe list
   pcrouter.exe 62 status
   pcrouter.exe 62 diag snap
   pcrouter.exe pc-62 test wan-failover -- 120 40
   pcrouter.exe pc-62 test --all 2h
   ```

`config.env` ищется рядом с `pcrouter.exe`. Логи и отчёты suite — в `dist/` (`tests.log`, `tmp/suite-*.json`).  
`push` возможен, если в `dist/PC-Router/` лежит полное дерево проекта.

Переменная `DEPLOY_CONFIG` / `SYSTEMA_DEVICE_ENV` — явный путь к другому файлу конфигурации.
