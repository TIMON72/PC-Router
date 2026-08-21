"""Tee stdout/stderr to tests/tests.log for deploy test runs."""
from __future__ import annotations

import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import IO, Callable

from .remote import active_id, device_name, project_root


class _Tee:
    streams: tuple[IO[str], ...]

    def __init__(self, *streams: IO[str]) -> None:
        self.streams = streams

    def write(self, data: str) -> int:
        for s in self.streams:
            s.write(data)
            s.flush()
        return len(data)

    def flush(self) -> None:
        for s in self.streams:
            s.flush()

    def isatty(self) -> bool:
        return False


def test_log_path() -> Path:
    path = project_root() / "tests" / "tests.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def with_test_log(fn: Callable[[], int]) -> int:
    path = test_log_path()
    fp = path.open("a", encoding="utf-8", errors="replace")
    stamp = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    fp.write(
        f"\n===== {stamp} ACTIVE={active_id()} device={device_name() or '-'} =====\n"
    )
    fp.flush()
    print(f"test log -> {path}", flush=True)

    old_out, old_err = sys.stdout, sys.stderr
    sys.stdout = _Tee(old_out, fp)  # type: ignore[assignment]
    sys.stderr = _Tee(old_err, fp)  # type: ignore[assignment]
    try:
        return fn()
    finally:
        sys.stdout = old_out
        sys.stderr = old_err
        fp.write(f"===== end {stamp} =====\n")
        fp.close()
