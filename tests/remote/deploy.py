#!/usr/bin/env python3
"""Upload local project to device and run upgrade-failover.sh."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from remote import REMOTE_ROOT, connect, project_root, run, upload_tree  # noqa: E402


def main() -> int:
    root = project_root()
    client = connect()
    sftp = client.open_sftp()
    # весь проект кроме .git и площадочного config.env (живёт в /etc на устройстве)
    skip_names = {"config.env"}
    rels = []
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if ".git" in p.parts or "__pycache__" in p.parts:
            continue
        if p.name.startswith("."):
            continue
        if p.name in skip_names:
            print("skip", p.relative_to(root).as_posix(), "(site-local on device)")
            continue
        rels.append(str(p.relative_to(root)).replace("\\", "/"))
    upload_tree(sftp, root, REMOTE_ROOT, rels)
    sftp.close()

    code, _, _ = run(
        client,
        f"cd {REMOTE_ROOT} && find . -type f \\( -name '*.sh' -o -name '*.service' "
        f"-o -name '*.py' -o -name 'config.env*' -o -name '*.env' \\) "
        f"-exec sed -i 's/\\r$//' {{}} +",
        timeout=120,
    )
    code, _, _ = run(
        client,
        f"bash -lc 'cd {REMOTE_ROOT} && bash scripts/upgrade-failover.sh'",
        use_sudo=True,
        timeout=180,
    )
    # Площадочный config.env на устройстве не перезаписываем шаблоном с ПК
    run(
        client,
        "bash -lc 'echo PROJECT=/home/admin/PC-Router; "
        "test ! -e /etc/systema-router && echo no_etc_systema_ok; "
        "test ! -e /usr/local/lib/systema-router && echo no_usr_local_lib_ok; "
        "grep -E \"^(DEVICE_|CAMERA_|ExecStart|Environment)\" /home/admin/PC-Router/config.env /etc/systemd/system/lte-failover.service | head -30; "
        "systemctl is-active lte lte-failover dnsmasq network-failsafe.timer; "
        "grep dhcp-host /etc/dnsmasq.d/50-pc-router-lan.conf /etc/dnsmasq.d/50-systema-cameras.conf 2>/dev/null | head -20'",
        use_sudo=True,
    )
    run(
        client,
        "bash -lc 'chmod -R a+rX /home/admin/PC-Router/tests'",
        use_sudo=True,
    )
    run(
        client,
        "systemctl is-active lte lte-failover network-failsafe.timer; "
        "test -x /home/admin/PC-Router/tests/run.sh && echo tests_ok",
    )
    client.close()
    return code


if __name__ == "__main__":
    raise SystemExit(main())
