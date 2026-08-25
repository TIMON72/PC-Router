"""CLI для выкладки PC-Router и удалённого запуска тестов.

Подготовка:
  copy deploy\\config.env.example deploy\\config.env

Команды:
  python -m deploy list
  python -m deploy <device> push
  python -m deploy <device> test --all <duration>
  python -m deploy <device> test <scenario> [-- args...]

Параметр --all: длительность (техн. мин. 300 с; полный прогон — от 1h).
  Пресеты: 300, 1h, 2h, 4h, 6h, 8h, 12h, 24h.
Устройство: DEVICE_NAME, id секции или HOST; иначе ACTIVE из deploy/config.env.
Журнал: tests/tests.log. Документация: deploy/README.md, tests/README.md.
"""
from __future__ import annotations

import sys

from .remote import list_devices, set_active

_COMMANDS = {"push", "test", "run", "list", "help", "-h", "--help"}


def _usage() -> None:
    print(__doc__.strip())


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in ("-h", "--help", "help"):
        _usage()
        return 0

    if args[0] == "list":
        rows = list_devices()
        if not rows:
            print("No devices in deploy/config.env")
            return 1
        for sid, name, host in rows:
            print(f"{sid}\t{name or '-'}\t{host or '-'}")
        return 0

    if args[0] not in _COMMANDS:
        set_active(args[0])
        args = args[1:]
        if not args:
            _usage()
            return 2

    cmd = args[0]
    rest = args[1:]

    if cmd == "push":
        from .push import push

        return push()
    if cmd in ("test", "run"):
        from .log import with_test_log

        if rest and rest[0] in ("--all", "all", "-a"):
            from .tests import parse_duration, run_all

            if len(rest) < 2:
                print(
                    "usage: python -m deploy <device> test --all <duration>\n"
                    "  e.g. --all 300 | --all 1h | --all 8h | --all 12h | --all 24h",
                    file=sys.stderr,
                )
                return 2
            try:
                return with_test_log(lambda: run_all(parse_duration(rest[1])))
            except KeyboardInterrupt:
                print("\nsuite interrupted", flush=True)
                return 130
        from .tests import run_one_scenario

        try:
            return with_test_log(lambda: run_one_scenario(rest))
        except KeyboardInterrupt:
            print("\ntest interrupted", flush=True)
            return 130

    print(f"unknown command: {cmd}", file=sys.stderr)
    _usage()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
