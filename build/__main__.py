"""Build pcrouter.exe into build/dist/.

Usage (from repo root):
  python -m build
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

BUILD_DIR = Path(__file__).resolve().parent
REPO_ROOT = BUILD_DIR.parent
DIST = BUILD_DIR / "dist"


def _run(cmd: list[str], *, cwd: Path | None = None) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.check_call(cmd, cwd=cwd or REPO_ROOT)


def _clean_stale_artifacts() -> None:
    """PyInstaller sometimes leaves build/pcrouter/ at repo root build/."""
    stale = BUILD_DIR / "pcrouter"
    if stale.is_dir():
        shutil.rmtree(stale, ignore_errors=True)


def _sync_config() -> None:
    """Тот же PC-side config, что и для python -m deploy."""
    example_src = BUILD_DIR / "config.env.example"
    example_dst = DIST / "config.env.example"
    shutil.copyfile(example_src, example_dst)

    deploy_cfg = REPO_ROOT / "deploy" / "config.env"
    dist_cfg = DIST / "config.env"
    if deploy_cfg.is_file():
        shutil.copyfile(deploy_cfg, dist_cfg)
        print("config: deploy/config.env → build/dist/config.env", flush=True)
        return
    if not dist_cfg.is_file():
        shutil.copyfile(example_dst, dist_cfg)
        print(
            "created build/dist/config.env from example — "
            "fill PASS or add deploy/config.env",
            flush=True,
        )


def main() -> int:
    _run([sys.executable, "-m", "pip", "install", "-q", "pyinstaller", "paramiko"])

    _clean_stale_artifacts()
    DIST.mkdir(parents=True, exist_ok=True)

    _run(
        [
            sys.executable,
            "-m",
            "PyInstaller",
            str(BUILD_DIR / "pcrouter.spec"),
            "--noconfirm",
            "--clean",
            "--distpath",
            str(DIST),
            "--workpath",
            str(BUILD_DIR / "_build"),
        ]
    )

    exe = DIST / "pcrouter.exe"
    if not exe.is_file():
        print(f"build failed: {exe} not found", file=sys.stderr)
        return 1

    _sync_config()

    print(f"\nOK: {exe}", flush=True)
    print("Copy build/dist/ to USB (pcrouter.exe + config.env).", flush=True)
    print("  pcrouter.exe list", flush=True)
    print("  pcrouter.exe pc-62 status", flush=True)
    print("  pcrouter.exe pc-62 diag snap", flush=True)
    print("  pcrouter.exe pc-62 test --all 2h", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
