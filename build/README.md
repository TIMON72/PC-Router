# build — сборка portable Windows tester (pcrouter.exe)

Исходники сборки — здесь. Готовый kit — в **`build/dist/`**.

```
PC-Router/
  build/
    __main__.py          ← python -m build
    field_entry.py
    pcrouter.spec
    config.env.example
    README.md
    _build/              (кэш PyInstaller, gitignore)
    dist/                (готовый kit, gitignore)
      pcrouter.exe
      config.env
```

Папки **`field-kit/`** и корневой **`dist/`** — старый layout, их можно удалить.

## Сборка (нужен Python на машине разработчика)

Из корня репозитория:

```powershell
python -m build
```

Запускайте из корня проекта — локальный пакет `build/` не должен путаться с pip-пакетом `build`.

При сборке, если есть `deploy/config.env`, он **автоматически копируется** в `build/dist/config.env` (ручное копирование не нужно; Cursor часто блокирует выделение полей с паролем).

Результат:

| Путь | В git | Назначение |
|------|-------|------------|
| `build/dist/pcrouter.exe` | нет | CLI тестов по SSH |
| `build/dist/config.env` | нет | HOST, PASS |
| `build/dist/config.env.example` | нет | образец (копируется при сборке) |
| `build/dist/tests.log`, `tmp/` | нет | логи прогонов |

## На объекте

Скопируйте **`build/dist/`** на USB и запускайте:

```text
cd dist
pcrouter.exe list
pcrouter.exe 62 status
pcrouter.exe 62 diag snap
pcrouter.exe pc-62 test --all 2h
```

`push` работает, если в `dist/PC-Router/` лежит полное дерево проекта.

Подробнее: [`deploy/README.md`](../deploy/README.md).
