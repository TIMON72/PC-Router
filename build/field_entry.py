"""PyInstaller entry point → pcrouter.exe (field kit, no Python on PC)."""
from __future__ import annotations

from deploy.__main__ import main

if __name__ == "__main__":
    raise SystemExit(main())
