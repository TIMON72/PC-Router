# deploy — удалённое обновление и тесты

Модуль рабочей станции для выкладки PC-Router на устройства и запуска `tests/` по SSH.

## Состав

| Модуль | Роль |
|--------|--------|
| `remote.py` | SSH/SFTP, чтение `config.env`, выбор устройства |
| `push.py` | Заливка дерева + `upgrade-failover.sh` |
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

## CLI

```text
python -m deploy list
python -m deploy <device> push
python -m deploy <device> test --all <duration>
python -m deploy <device> test <scenario> [-- args…]
```

`<device>` — `DEVICE_NAME`, id секции или `HOST`. Если опущен, используется `ACTIVE` из `deploy/config.env`.

`test --all` требует длительность. Технический минимум 300 с; для полного прогона без ужимания окон — **`1h`** (около 40 мин на один круг). Пресеты: `300`, `1h`, `2h`, `4h`, `6h`, `8h`, `12h`, `24h` (см. [`tests/README.md`](../tests/README.md)).

Журнал прогонов: `tests/tests.log`.
