# tests/ — диагностика и сценарии PC-Router

Архитектура для локальной разработки и прогона **на устройстве**. Продакшен-логика остаётся в `scripts/`; здесь — снимок состояния, искусственные обрывы и remote-хелперы.

```
tests/
  README.md           ← этот файл
  run.sh              ← единая точка входа на устройстве
  lib/
    common.sh         ← snap, require_root, test.env begin/end
    remote.py         ← SSH/SFTP без паролей в репозитории
  diag/
    snapshot.sh       ← интерфейсы / маршруты / сервисы / APN
    recent-events.sh  ← хвост logs.log по тегам
  scenarios/
    wan-failover.sh       ← WAN down → LTE → WAN back (с deadline)
    lte-soft-fail.sh      ← ICMP drop на ppp0; APN не крутится сразу
    outage-escalation.sh  ← короткий outage + REBOOT_DRY_RUN
  fixtures/
    fast-failover.env     ← короткие cooldown / пороги
    fast-outage.env       ← короткий schedule reboot + DRY_RUN
  remote/
    deploy.py             ← залить проект с ПК на устройство
    run.py                ← выполнить tests/run.sh по SSH
```

## Принципы

1. **Любой сценарий обязан уметь cleanup** (`trap EXIT`) и не оставлять `hold-wan-down` / `test.env`.
2. **Ускорение без часовых ожиданий** — через `/run/systema-router/test.env` (подхватывают `lte-failover` и `network-failsafe`). Реальный reboot в тестах по умолчанию **запрещён** (`REBOOT_DRY_RUN=1`).
3. **Пароли не в git.** Remote: `SYSTEMA_HOST`, `SYSTEMA_USER`, `SYSTEMA_PASS` (или SSH-ключ). Каталог на устройстве: `SYSTEMA_REMOTE_ROOT` (по умолчанию `/home/admin/PC-Router`).
4. Код правится **в этом репозитории**, затем деплоится на mini-PC (`tests/remote/deploy.py` или `upgrade-failover.sh`).

## На устройстве

```bash
cd ~/PC-Router
sudo bash tests/run.sh list
sudo bash tests/run.sh snap
sudo bash tests/run.sh events 80
sudo bash tests/run.sh wan-failover 120 40
sudo bash tests/run.sh lte-soft-fail
sudo bash tests/run.sh outage-dry
```

Совместимость: `sudo safe-failover-test.sh` → тот же `wan-failover`.

## С ПК (Windows / PowerShell)

```powershell
$env:SYSTEMA_HOST = "10.x.x.x"
$env:SYSTEMA_USER = "admin"
$env:SYSTEMA_PASS = "..."   # не коммитить

python tests/remote/deploy.py
python tests/remote/run.py snap
python tests/remote/run.py wan-failover -- 120 40
python tests/remote/run.py outage-dry
```
