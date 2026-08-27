"""CLI для выкладки PC-Router и удалённого запуска тестов.

Подготовка (из исходников):
  copy deploy\\config.env.example deploy\\config.env

Полевой kit (pcrouter.exe на Windows):
  build/dist/config.env   (см. build/config.env.example)

Команды:
  {cli} list
  {cli} <device> push
  {cli} <device> status [days]          — сервисный отчёт (по умолчанию 1 день)
  {cli} <device> diag <cmd> [-- args…]  — любая diag-команда (snap, dhcp-lan, …)
  {cli} <device> test --all <duration>
  {cli} <device> test <scenario> [-- args...]

Параметр --all: длительность (минимум **1h**).
  Пресеты: 1h, 2h, 4h, 6h, 8h, 12h, 24h.
Устройство: DEVICE_NAME, id секции или HOST; иначе ACTIVE из config.env.
Журнал: tests.log (рядом с exe) или tests/tests.log (из исходников).
"""
from __future__ import annotations

import sys

from .paths import cli_name, config_hint
from .remote import list_devices, set_active

_COMMANDS = {"push", "test", "run", "diag", "list", "help", "-h", "--help"}


def _usage() -> None:
    print(__doc__.format(cli=cli_name()).strip())
    print(f"\nConfig: {config_hint()}", flush=True)


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in ("-h", "--help", "help"):
        _usage()
        return 0

    if args[0] == "list":
        rows = list_devices()
        if not rows:
            print(f"No devices in {config_hint()}")
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
    from .log import with_test_log
    from .tests import DIAG_COMMANDS, run_one_scenario

    def _run_remote(rest_args: list[str], *, interrupt_label: str) -> int:
        if not rest_args:
            return 2
        try:
            return with_test_log(lambda: run_one_scenario(rest_args))
        except KeyboardInterrupt:
            print(f"\n{interrupt_label} interrupted", flush=True)
            return 130

    if cmd == "diag":
        if not rest:
            print(
                f"usage: {cli_name()} <device> diag <command> [-- args...]\n"
                "  e.g. diag snap | diag status 7 | diag dhcp-lan",
                file=sys.stderr,
            )
            return 2
        return _run_remote(rest, interrupt_label="diag")

    if cmd in DIAG_COMMANDS:
        return _run_remote([cmd] + rest, interrupt_label=cmd)

    if cmd in ("test", "run"):
        if rest and rest[0] in ("--all", "all", "-a"):
            from .tests import parse_duration, run_all

            if len(rest) < 2:
                print(
                    f"usage: {cli_name()} <device> test --all <duration>\n"
                    "  e.g. --all 1h | --all 2h | --all 8h | --all 12h | --all 24h\n"
                    "  minimum: 1h",
                    file=sys.stderr,
                )
                return 2
            try:
                return with_test_log(lambda: run_all(parse_duration(rest[1])))
            except KeyboardInterrupt:
                print("\nsuite interrupted", flush=True)
                return 130
        if not rest:
            print(
                f"usage: {cli_name()} <device> test <scenario> [-- args...]\n"
                f"  diag on device: {cli_name()} <device> status | diag snap | …",
                file=sys.stderr,
            )
            return 2
        return _run_remote(rest, interrupt_label="test")

    print(f"unknown command: {cmd}", file=sys.stderr)
    _usage()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
