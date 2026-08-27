"""Paths for deploy CLI: dev tree (python -m deploy) vs field kit (build/dist/pcrouter.exe)."""
from __future__ import annotations

import os
import sys
from pathlib import Path

_DEPLOY_DIR = Path(__file__).resolve().parent
_REPO_ROOT = _DEPLOY_DIR.parent


def is_frozen() -> bool:
    return bool(getattr(sys, "frozen", False))


def app_dir() -> Path:
    """Config and (when frozen) all local output live here."""
    if is_frozen():
        return Path(sys.executable).resolve().parent
    return _DEPLOY_DIR


def workspace_dir() -> Path:
    """Writable logs and suite reports."""
    if is_frozen():
        return app_dir()
    return _REPO_ROOT


def config_search_paths() -> list[Path]:
    out: list[Path] = []
    for key in ("DEPLOY_CONFIG", "SYSTEMA_DEVICE_ENV"):
        val = os.environ.get(key, "").strip()
        if val:
            out.append(Path(val))
    out.append(app_dir() / "config.env")
    if not is_frozen():
        legacy = _DEPLOY_DIR / "config.env"
        if legacy not in out:
            out.append(legacy)
    return out


def resolve_config_path() -> Path | None:
    for path in config_search_paths():
        if path.is_file():
            return path
    return None


def config_hint() -> str:
    if is_frozen():
        return f"config.env next to {Path(sys.executable).name}"
    return "deploy/config.env (copy from config.env.example)"


def cli_name() -> str:
    if is_frozen():
        return Path(sys.executable).name
    return "python -m deploy"


def project_root() -> Path:
    if is_frozen():
        base = app_dir()
        for name in ("PC-Router", "payload"):
            root = base / name
            if (root / "scripts" / "upgrade-failover.sh").is_file():
                return root
        if (_REPO_ROOT / "scripts" / "upgrade-failover.sh").is_file():
            return _REPO_ROOT
        return base
    return _REPO_ROOT
