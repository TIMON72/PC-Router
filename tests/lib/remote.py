#!/usr/bin/env python3
"""SSH/SFTP helpers for PC-Router tests. Credentials via env only."""
from __future__ import annotations

import os
import sys
from pathlib import Path

import paramiko

DEFAULT_HOST = os.environ.get("SYSTEMA_HOST", "")
DEFAULT_USER = "admin"
REMOTE_ROOT = os.environ.get("SYSTEMA_REMOTE_ROOT", "/home/admin/PC-Router")


def env_creds() -> tuple[str, str, str]:
    host = os.environ.get("SYSTEMA_HOST", DEFAULT_HOST)
    user = os.environ.get("SYSTEMA_USER", DEFAULT_USER)
    password = os.environ.get("SYSTEMA_PASS", "")
    if not host:
        print("Set SYSTEMA_HOST (and SYSTEMA_PASS or SYSTEMA_SSH_KEY)", file=sys.stderr)
        sys.exit(2)
    if not password and not os.environ.get("SYSTEMA_SSH_KEY"):
        print(
            "Set SYSTEMA_PASS or SYSTEMA_SSH_KEY (and optional SYSTEMA_USER)",
            file=sys.stderr,
        )
        sys.exit(2)
    return host, user, password


def connect() -> paramiko.SSHClient:
    host, user, password = env_creds()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    key = os.environ.get("SYSTEMA_SSH_KEY")
    kwargs: dict = {
        "hostname": host,
        "username": user,
        "timeout": 25,
        "allow_agent": True,
        "look_for_keys": True,
    }
    if key:
        kwargs["key_filename"] = key
        kwargs["look_for_keys"] = False
        kwargs["allow_agent"] = False
    elif password:
        kwargs["password"] = password
        kwargs["allow_agent"] = False
        kwargs["look_for_keys"] = False
    client.connect(**kwargs)
    return client


def sudo_prefix(password: str) -> str:
    if password:
        # -S reads password from stdin; quote-safe via single-quoted echo
        safe = password.replace("'", "'\"'\"'")
        return f"echo '{safe}' | sudo -S "
    return "sudo -n "


def run(
    client: paramiko.SSHClient,
    cmd: str,
    *,
    timeout: int = 300,
    use_sudo: bool = False,
) -> tuple[int, str, str]:
    _, _, password = env_creds()
    if use_sudo:
        cmd = sudo_prefix(password) + cmd
    shown = cmd
    if password:
        shown = shown.replace(password, "***")
    print("$", shown)
    _stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if out:
        print(out, end="" if out.endswith("\n") else "\n")
    filtered = "\n".join(
        line for line in err.splitlines() if "password" not in line.lower()
    )
    if filtered.strip():
        print("ERR:", filtered[:4000], file=sys.stderr)
    return code, out, err


def ensure_remote_dir(sftp: paramiko.SFTPClient, remote: str) -> None:
    parts = remote.strip("/").split("/")
    cur = ""
    for part in parts:
        cur += "/" + part
        try:
            sftp.stat(cur)
        except FileNotFoundError:
            try:
                sftp.mkdir(cur)
            except OSError:
                pass


def upload_tree(
    sftp: paramiko.SFTPClient,
    local_root: Path,
    remote_root: str,
    rel_paths: list[str] | None = None,
) -> None:
    if rel_paths is None:
        rel_paths = []
        for p in local_root.rglob("*"):
            if p.is_file() and "__pycache__" not in p.parts and p.name != ".git":
                rel_paths.append(str(p.relative_to(local_root)).replace("\\", "/"))
    for rel in rel_paths:
        local = local_root / rel
        if not local.is_file():
            continue
        remote = f"{remote_root}/{rel}"
        ensure_remote_dir(sftp, str(Path(remote).parent).replace("\\", "/"))
        data = local.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        with sftp.file(remote, "wb") as rf:
            rf.write(data)
        print("put", rel)


def project_root() -> Path:
    return Path(__file__).resolve().parents[2]
