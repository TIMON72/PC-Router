# PyInstaller spec: field kit console tool (SSH tests without Python on PC).
# Build:  python -m build   (from repo root)

from pathlib import Path

BUILD = Path(SPECPATH).resolve()
ROOT = BUILD.parent

a = Analysis(
    [str(BUILD / "field_entry.py")],
    pathex=[str(ROOT)],
    binaries=[],
    datas=[],
    hiddenimports=[
        "paramiko",
        "cryptography",
        "bcrypt",
        "nacl",
        "invoke",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="pcrouter",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
