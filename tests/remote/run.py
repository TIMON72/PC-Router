#!/usr/bin/env python3
"""Run tests/run.sh on the device via SSH.

Examples:
  python tests/remote/run.py snap
  python tests/remote/run.py wan-failover -- 120 40
  python tests/remote/run.py outage-dry
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from remote import REMOTE_ROOT, connect, run  # noqa: E402


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    # allow: run.py wan-failover -- 120 40
    if "--" in args:
        i = args.index("--")
        cmd_args = args[:i] + args[i + 1 :]
    else:
        cmd_args = args

    quoted = " ".join(f"'{a}'" if " " in a else a for a in cmd_args)
    remote_cmd = f"bash {REMOTE_ROOT}/tests/run.sh {quoted}"
    client = connect()
    # long scenarios need long timeout
    timeout = 600
    if cmd_args and cmd_args[0] in ("snap", "events", "list", "help"):
        timeout = 60
    code, _, _ = run(client, remote_cmd, use_sudo=True, timeout=timeout)
    client.close()
    return code


if __name__ == "__main__":
    raise SystemExit(main())
