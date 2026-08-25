"""SSH/SFTP helpers for deploy.

Credentials: env SYSTEMA_* > deploy/config.env > defaults.
See deploy/config.env.example.
"""
from __future__ import annotations

import logging
import os
import sys
import time
from collections.abc import Callable
from pathlib import Path

import paramiko  # type: ignore

_DEPLOY_DIR = Path(__file__).resolve().parent
_CONFIG = _DEPLOY_DIR / "config.env"


def quiet_paramiko() -> None:
    """Глушим paramiko: иначе при обрыве VPN в консоль лезет 'Socket exception: …10054'."""
    for name in ("paramiko", "paramiko.transport"):
        log = logging.getLogger(name)
        log.setLevel(logging.CRITICAL)
        log.propagate = False
        log.handlers.clear()


quiet_paramiko()


def _parse_env_file(path: Path) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    globals_: dict[str, str] = {}
    sections: dict[str, dict[str, str]] = {}
    current: str | None = None
    if not path.is_file():
        return globals_, sections
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip()
            _ = sections.setdefault(current, {})
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip().strip("'").strip('"')
        if not key:
            continue
        if current is None:
            globals_[key] = val
        else:
            sections[current][key] = val
    return globals_, sections


def _load_raw() -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    g, sections = _parse_env_file(_CONFIG)
    alt = os.environ.get("SYSTEMA_DEVICE_ENV", "") or os.environ.get(
        "DEPLOY_CONFIG", ""
    )
    if alt:
        g2, s2 = _parse_env_file(Path(alt))
        g.update(g2)
        for name, body in s2.items():
            sections.setdefault(name, {}).update(body)
    return g, sections


_GLOBALS, _SECTIONS = _load_raw()
_active_override: str | None = None


def list_devices() -> list[tuple[str, str, str]]:
    """Return [(section_id, DEVICE_NAME, HOST), ...]."""
    out: list[tuple[str, str, str]] = []
    for sid, body in _SECTIONS.items():
        out.append(
            (
                sid,
                body.get("DEVICE_NAME", ""),
                body.get("HOST", ""),
            )
        )
    return out


def resolve_device(token: str) -> str:
    """Map CLI token (section id / DEVICE_NAME / HOST) → section id."""
    t = token.strip()
    if not t:
        raise SystemExit("empty device name")
    if t in _SECTIONS:
        return t
    t_low = t.lower()
    for sid, body in _SECTIONS.items():
        name = body.get("DEVICE_NAME", "").strip()
        host = body.get("HOST", "").strip()
        if name.lower() == t_low or host == t:
            return sid
    known = ", ".join(
        f"{sid}({body.get('DEVICE_NAME') or '-'})" for sid, body in _SECTIONS.items()
    )
    print(
        f"Unknown device {token!r}. Known: {known or '(none in deploy/config.env)'}",
        file=sys.stderr,
    )
    raise SystemExit(2)


def set_active(device: str) -> str:
    """Select device for subsequent connect/push/test. Returns section id."""
    global _active_override
    _active_override = resolve_device(device)
    return _active_override


def active_id() -> str:
    if _active_override:
        return _active_override
    return (
        os.environ.get("SYSTEMA_ACTIVE", "").strip()
        or _GLOBALS.get("ACTIVE", "").strip()
        or "62"
    )


def device_name() -> str:
    return _cfg("DEVICE_NAME", "SYSTEMA_DEVICE_NAME", default="")


def remote_root() -> str:
    return _cfg(
        "REMOTE_ROOT", "SYSTEMA_REMOTE_ROOT", default="/home/admin/PC-Router"
    )


def _active_body() -> dict[str, str]:
    aid = active_id()
    body = dict(_SECTIONS.get(aid, {}))
    if not body and not _SECTIONS:
        body = dict(_GLOBALS)
    return body


def _cfg(key: str, *env_keys: str, default: str = "") -> str:
    for ek in env_keys:
        v = os.environ.get(ek, "")
        if v:
            return v
    body = _active_body()
    if key in body and body[key]:
        return body[key]
    if key in _GLOBALS and _GLOBALS[key]:
        return _GLOBALS[key]
    return default


def env_creds() -> tuple[str, str, str]:
    host = _cfg("HOST", "SYSTEMA_HOST", default="")
    user = _cfg("USER", "SYSTEMA_USER", default="admin")
    password = _cfg("PASS", "SYSTEMA_PASS", default="")
    if not host:
        print(
            "Set HOST for ACTIVE in deploy/config.env (from config.env.example) or SYSTEMA_HOST",
            file=sys.stderr,
        )
        sys.exit(2)
    key = _cfg("SSH_KEY", "SYSTEMA_SSH_KEY", default="")
    if not password and not key:
        print(
            "Set PASS for ACTIVE in deploy/config.env or SYSTEMA_PASS / SYSTEMA_SSH_KEY",
            file=sys.stderr,
        )
        sys.exit(2)
    if key and "SYSTEMA_SSH_KEY" not in os.environ:
        os.environ["SYSTEMA_SSH_KEY"] = key
    return host, user, password


def connect(
    *,
    fatal: bool = True,
    quiet: bool = False,
    timeout: float = 25,
) -> paramiko.SSHClient:
    """Open SSH. If fatal=False, raise on error (for suite reconnect); else sys.exit(1)."""
    host, user, password = env_creds()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    key = os.environ.get("SYSTEMA_SSH_KEY") or _cfg("SSH_KEY", default="")
    target = f"{user}@{host}"
    if not quiet:
        print(
            f"SSH {target} (ACTIVE={active_id()} {device_name() or ''})".strip()
        )
    try:
        if key:
            client.connect(
                hostname=host,
                username=user,
                key_filename=key,
                timeout=timeout,
                allow_agent=False,
                look_for_keys=False,
            )
        else:
            client.connect(
                hostname=host,
                username=user,
                password=password,
                timeout=timeout,
                allow_agent=False,
                look_for_keys=False,
            )
    except (TimeoutError, OSError, paramiko.SSHException) as e:
        reason = type(e).__name__
        if isinstance(e, TimeoutError) or "timed out" in str(e).lower():
            reason = "timeout"
        elif "Authentication" in type(e).__name__ or "auth" in str(e).lower():
            reason = "auth failed"
        if not quiet:
            print(f"SSH failed: {target} ({reason})", file=sys.stderr)
        if fatal:
            sys.exit(1)
        raise
    return client


# Optional hook from deploy.tests — перенос строки перед долгим SSH wait
before_reconnect_log: Callable[[], None] | None = None


def reconnect_with_retry(
    *,
    # Крайнее время на подъём VPN после WAN↓ / ladder (без логов по попыткам)
    deadline_sec: float = 180.0,
    connect_timeout: float = 30.0,
    retry_pause_sec: float = 10.0,
) -> paramiko.SSHClient:
    """Тихо ждать SSH до deadline_sec; иначе ConnectionError → тест FAIL."""
    if before_reconnect_log is not None:
        before_reconnect_log()
    last: BaseException | None = None
    deadline = time.time() + deadline_sec
    while time.time() < deadline:
        try:
            return connect(fatal=False, quiet=True, timeout=connect_timeout)
        except (TimeoutError, OSError, paramiko.SSHException) as e:
            last = e
            left = deadline - time.time()
            if left <= 0:
                break
            time.sleep(min(retry_pause_sec, max(1.0, left)))
    raise ConnectionError(
        f"SSH not back within {int(deadline_sec)}s"
    ) from last


def sudo_prefix(password: str) -> str:
    if password:
        safe = password.replace("'", "'\"'\"'")
        return f"echo '{safe}' | sudo -S "
    return "sudo -n "


def run(
    client: paramiko.SSHClient,
    cmd: str,
    *,
    timeout: int = 300,
    use_sudo: bool = False,
    quiet: bool = False,
) -> tuple[int, str, str]:
    _, _, password = env_creds()
    if use_sudo:
        cmd = sudo_prefix(password) + cmd
    shown = cmd
    if password:
        shown = shown.replace(password, "***")
    if not quiet:
        print("$", shown)
    try:
        _stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        code = stdout.channel.recv_exit_status()
    except (OSError, EOFError, paramiko.SSHException, TimeoutError) as e:
        # Обрыв VPN mid-read — без traceback/socket spam в консоль suite
        raise ConnectionError(f"SSH lost: {type(e).__name__}") from e
    if not quiet:
        if out:
            print(out, end="" if out.endswith("\n") else "\n")
        filtered = "\n".join(
            line
            for line in err.splitlines()
            if "password" not in line.lower()
            and "socket exception" not in line.lower()
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
            sftp.mkdir(cur)
        except OSError:
            pass


def upload_tree(
    sftp: paramiko.SFTPClient,
    local_root: Path,
    remote_root: str,
    rel_paths: list[str] | None = None,
    *,
    quiet: bool = False,
) -> int:
    if rel_paths is None:
        rel_paths = []
        for p in local_root.rglob("*"):
            if p.is_file() and "__pycache__" not in p.parts and p.name != ".git":
                if "tmp" in p.parts:
                    continue
                rel_paths.append(str(p.relative_to(local_root)).replace("\\", "/"))
    count = 0
    for rel in rel_paths:
        local = local_root / rel
        if not local.is_file():
            continue
        remote = f"{remote_root}/{rel}"
        ensure_remote_dir(sftp, str(Path(remote).parent).replace("\\", "/"))
        data = local.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        with sftp.file(remote, "wb") as rf:
            rf.write(data)
        count += 1
        if not quiet:
            print("put", rel)
    return count


def project_root() -> Path:
    return Path(__file__).resolve().parents[1]
