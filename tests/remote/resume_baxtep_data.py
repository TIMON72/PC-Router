#!/usr/bin/env python3
"""Resume/upload BAXTEP data/ to .60 (exclude temp). Stage→mv→chown baxtep_tko."""
from __future__ import annotations

import os
import subprocess
import sys
import time

import paramiko

HOST = os.environ.get("SYSTEMA_HOST", "10.181.19.60")
USER = os.environ.get("SYSTEMA_USER", "admin")
PASS = os.environ.get("SYSTEMA_PASS", "")
LOCAL_DATA = os.environ.get(
    "BAXTEP_DATA_SRC",
    r"C:\Users\rtv25\Projects\BAXTEP\trash\baxtep_tko\data",
)
REMOTE_DATA = os.environ.get("BAXTEP_DATA_DST", "/home/baxtep_tko/BAXTEP/data")
STAGE = "/var/tmp/baxtep_data_stage"


def main() -> int:
    if not PASS:
        print("SYSTEMA_PASS required", file=sys.stderr)
        return 2
    if not os.path.isdir(LOCAL_DATA):
        print(f"missing {LOCAL_DATA}", file=sys.stderr)
        return 2

    safe = PASS.replace("'", "'\"'\"'")
    sudo = f"echo '{safe}' | sudo -S -p ''"

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        HOST,
        username=USER,
        password=PASS,
        timeout=30,
        allow_agent=False,
        look_for_keys=False,
        banner_timeout=60,
    )

    # cleanup stale tar/stage; prepare writable stage for admin
    prep = (
        f"{sudo} bash -lc '"
        f"pkill -9 -f \"tar -xf - -C /var/tmp/baxtep\" || true; "
        f"pkill -9 -f \"tar -xf - -C /home/baxtep_tko/BAXTEP/data\" || true; "
        f"sleep 1; "
        f"rm -rf {STAGE}; mkdir -p {STAGE}; chown {USER}:{USER} {STAGE}; chmod 755 {STAGE}; "
        f"df -h / | sed -n \"1,2p\"; "
        f"ps aux | grep \"tar -xf\" | grep -v grep || echo no_stale_tar'"
    )
    _, out, err = c.exec_command(prep, timeout=60)
    print(out.read().decode("utf-8", "replace"))
    for line in err.read().decode("utf-8", "replace").splitlines():
        if "password" not in line.lower() and line.strip():
            print("ERR:", line)

    transport = c.get_transport()
    assert transport
    transport.set_keepalive(30)

    # verify stage writable before streaming
    _, out, err = c.exec_command(
        f"test -w {STAGE} && echo STAGE_OK || echo STAGE_BAD; ls -ld {STAGE}",
        timeout=30,
    )
    print(out.read().decode("utf-8", "replace"), end="")
    print(err.read().decode("utf-8", "replace")[:500])

    ch = transport.open_session()
    ch.settimeout(None)
    # Use bash -lc so errors show up if STAGE missing
    ch.exec_command(f"bash -lc 'set -e; test -d {STAGE}; tar -xf - -C {STAGE}'")

    tar_cmd = [
        "tar",
        "-cf",
        "-",
        "--exclude=temp",
        "--exclude=./temp",
        "-C",
        LOCAL_DATA,
        ".",
    ]
    print(f"streaming data/ → {HOST}:{STAGE} (~30GB, LTE — долго)", flush=True)
    t0 = time.time()
    proc = subprocess.Popen(tar_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdout is not None
    sent = 0
    last = t0
    try:
        while True:
            if ch.exit_status_ready():
                remote_err = ""
                while ch.recv_stderr_ready():
                    remote_err += ch.recv_stderr(65536).decode("utf-8", "replace")
                code = ch.recv_exit_status()
                print(f"remote tar exited early code={code} err={remote_err[:2000]}", flush=True)
                proc.kill()
                c.close()
                return code or 1
            chunk = proc.stdout.read(1024 * 1024)
            if not chunk:
                break
            ch.sendall(chunk)
            sent += len(chunk)
            now = time.time()
            if now - last >= 15:
                mb = sent / 1e6
                rate = mb / max(now - t0, 1)
                eta_h = ((30557 - mb) / max(rate, 0.01)) / 3600
                print(f"  {mb:.0f} MB ({rate:.2f} MB/s) ETA~{eta_h:.1f}h", flush=True)
                last = now
        ch.shutdown_write()
    except OSError as e:
        remote_err = ""
        try:
            while ch.recv_stderr_ready():
                remote_err += ch.recv_stderr(65536).decode("utf-8", "replace")
        except Exception:
            pass
        print(f"socket error: {e}; remote_err={remote_err[:2000]}", flush=True)
        proc.kill()
        c.close()
        return 1

    tar_err = proc.stderr.read().decode("utf-8", "replace") if proc.stderr else ""
    proc.wait(timeout=120)
    while not ch.exit_status_ready():
        if ch.recv_ready():
            ch.recv(65536)
        if ch.recv_stderr_ready():
            sys.stderr.write(ch.recv_stderr(65536).decode("utf-8", "replace"))
        time.sleep(0.2)
    remote_code = ch.recv_exit_status()
    ch.close()
    print(
        f"stream done local={proc.returncode} remote={remote_code} "
        f"{sent/1e6:.0f} MB in {time.time()-t0:.0f}s",
        flush=True,
    )
    if tar_err.strip():
        print("tar stderr:", tar_err[:1500])
    if proc.returncode or remote_code:
        c.close()
        return proc.returncode or remote_code

    # Replace destination atomically-ish: merge into data, then chown
    finalize = f"""{sudo} bash -lc '
set -euo pipefail
mkdir -p {REMOTE_DATA}
# move staged tree into place (same FS → cheap); keep existing extra files
cp -a {STAGE}/. {REMOTE_DATA}/
rm -rf {STAGE}
rm -rf {REMOTE_DATA}/temp
chown -R baxtep_tko:baxtep_tko {REMOTE_DATA}
find {REMOTE_DATA} -type d -exec chmod u+rwx,g+rx,o-rwx {{}} +
find {REMOTE_DATA} -type f -exec chmod u+rw,g+r,o-rwx {{}} +
echo files=$(find {REMOTE_DATA} -type f | wc -l)
du -sh {REMOTE_DATA}
stat -c "owner=%U:%G mode=%a" {REMOTE_DATA}
sudo -u baxtep_tko bash -lc "echo ok > {REMOTE_DATA}/.w && rm -f {REMOTE_DATA}/.w && echo write_ok"
'"""
    print("finalizing…", flush=True)
    _, out, err = c.exec_command(finalize, timeout=3600)
    print(out.read().decode("utf-8", "replace"))
    for line in err.read().decode("utf-8", "replace").splitlines():
        if "password" not in line.lower() and line.strip():
            print("ERR:", line)
    code = out.channel.recv_exit_status()
    c.close()
    if code == 0:
        print("=== DATA OK ===", flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
