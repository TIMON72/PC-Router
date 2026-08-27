"""Upload local project to ACTIVE device and run upgrade-failover.sh."""
from __future__ import annotations

import sys
from pathlib import Path

from .paths import app_dir, cli_name
from .remote import connect, project_root, remote_root, run, upload_tree

# Never push site/secrets configs onto the device from the PC tree.
_SKIP_NAMES = {"config.env"}
_SKIP_REL_PREFIXES = ("deploy/config.env",)

# PC-only / dev: не заливать на роутер (python -m deploy push).
_SKIP_DIR_NAMES = frozenset({
    ".git",
    "__pycache__",
    "tmp",
    "build",
    "deploy",
    "dist",
    "field-kit",
    ".venv",
    "venv",
    ".cursor",
    ".idea",
    ".vscode",
})

# Если раньше залили целиком репо — убрать с устройства при push.
_REMOTE_PRUNE_DIRS = ("build", "deploy", "dist", "field-kit", ".venv", "venv")


def _push_skip_reason(rel: str, path: Path) -> str | None:
    if any(part in _SKIP_DIR_NAMES for part in Path(rel).parts):
        return "dev"
    if path.name.startswith("."):
        return "dot"
    if path.name in _SKIP_NAMES or rel in _SKIP_REL_PREFIXES:
        return "secret"
    return None


def _prune_remote_dev(client, root_remote: str) -> list[str]:
    """Удалить PC-only каталоги, оставшиеся от старых push."""
    quoted = " ".join(_REMOTE_PRUNE_DIRS)
    cmd = (
        f"bash -lc 'cd {root_remote} && for d in {quoted}; do "
        f"if [[ -e \"$d\" ]]; then rm -rf \"$d\" && echo \"$d\"; fi; done'"
    )
    _, out, _ = run(client, cmd, use_sudo=True, timeout=60, quiet=True)
    return [ln.strip() for ln in (out or "").splitlines() if ln.strip()]


def push() -> int:
    root = project_root()
    if not (root / "scripts" / "upgrade-failover.sh").is_file():
        print(
            f"push: no PC-Router tree (need scripts/upgrade-failover.sh).\n"
            f"  Field kit: put full repo in {app_dir() / 'PC-Router'} or use "
            f"{cli_name()} test … (tests already on device).",
            file=sys.stderr,
        )
        return 2
    root_remote = remote_root()
    client = connect()
    sftp = client.open_sftp()
    rels: list[str] = []
    skipped = 0
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        rel = str(p.relative_to(root)).replace("\\", "/")
        if _push_skip_reason(rel, p):
            skipped += 1
            continue
        rels.append(rel)

    print(f"upload → {root_remote} …", flush=True, end="")
    n = upload_tree(sftp, root, root_remote, rels, quiet=True)
    sftp.close()
    print(f" {n} files (skipped local/dev={skipped})", flush=True)

    pruned = _prune_remote_dev(client, root_remote)
    if pruned:
        print(f"prune remote dev: {' '.join(pruned)}", flush=True)

    print("normalize CRLF …", flush=True, end="")
    run(
        client,
        f"cd {root_remote} && find . -type f \\( -name '*.sh' -o -name '*.service' "
        f"-o -name '*.py' -o -name 'config.env*' -o -name '*.env' \\) "
        f"-exec sed -i 's/\\r$//' {{}} +",
        timeout=120,
        quiet=True,
    )
    print(" ok", flush=True)

    print("upgrade-failover …", flush=True, end="")
    code, out, err = run(
        client,
        f"bash -lc 'cd {root_remote} && bash scripts/upgrade-failover.sh'",
        use_sudo=True,
        timeout=180,
        quiet=True,
    )
    text = f"{out or ''}\n{err or ''}"
    ok_line = next(
        (ln.strip() for ln in text.splitlines() if ln.startswith("OK PROJECT=")),
        "",
    )
    if code == 0:
        print(f" ok ({ok_line})" if ok_line else " ok", flush=True)
    else:
        print(f" FAIL exit={code}", flush=True)
        tail = "\n".join(text.splitlines()[-8:])
        if tail.strip():
            print(tail, flush=True)

    print("services …", flush=True, end="")
    _, svc_out, _ = run(
        client,
        f"bash -lc 'systemctl is-active lte lte-failover dnsmasq network-failsafe.timer; "
        f"test -x {root_remote}/tests/run.sh && echo tests_ok'",
        use_sudo=True,
        quiet=True,
    )
    parts = [p.strip() for p in svc_out.splitlines() if p.strip()]
    print(" " + " ".join(parts), flush=True)

    run(
        client,
        f"bash -lc 'chmod -R a+rX {root_remote}/tests'",
        use_sudo=True,
        quiet=True,
    )
    client.close()
    print("push OK" if code == 0 else "push FAIL", flush=True)
    return code
