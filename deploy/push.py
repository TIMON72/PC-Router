"""Upload local project to ACTIVE device and run upgrade-failover.sh."""
from __future__ import annotations

from .remote import connect, project_root, remote_root, run, upload_tree

# Never push site/secrets configs onto the device from the PC tree.
_SKIP_NAMES = {"config.env"}
_SKIP_REL_PREFIXES = ("deploy/config.env",)


def push() -> int:
    root = project_root()
    root_remote = remote_root()
    client = connect()
    sftp = client.open_sftp()
    rels: list[str] = []
    skipped = 0
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if ".git" in p.parts or "__pycache__" in p.parts or "tmp" in p.parts:
            continue
        if p.name.startswith("."):
            continue
        rel = str(p.relative_to(root)).replace("\\", "/")
        if p.name in _SKIP_NAMES or rel in _SKIP_REL_PREFIXES:
            skipped += 1
            continue
        rels.append(rel)

    print(f"upload → {root_remote} …", flush=True, end="")
    n = upload_tree(sftp, root, root_remote, rels, quiet=True)
    sftp.close()
    print(f" {n} files (skip secrets={skipped})", flush=True)

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
