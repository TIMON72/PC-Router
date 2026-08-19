#!/usr/bin/env python3
"""Upload BAXTEP dump to .60: mains first (no temp/data), optional data later."""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

import paramiko

HOST = os.environ.get("SYSTEMA_HOST", "10.181.19.60")
USER = os.environ.get("SYSTEMA_USER", "admin")
PASS = os.environ.get("SYSTEMA_PASS", "")
LOCAL = os.environ.get(
    "BAXTEP_SRC",
    r"C:\Users\rtv25\Projects\BAXTEP\trash\baxtep_tko",
)
REMOTE = os.environ.get("BAXTEP_DST", "/home/baxtep_tko/BAXTEP")
STAGE = "/var/tmp/baxtep_stage_upload"


def ssh_run(client: paramiko.SSHClient, cmd: str, timeout: int = 300) -> tuple[int, str, str]:
    _, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    return stdout.channel.recv_exit_status(), out, err


def stream_tar(
    client: paramiko.SSHClient,
    local_cwd: str,
    remote_dir: str,
    excludes: list[str],
    label: str,
) -> int:
    transport = client.get_transport()
    assert transport is not None
    channel = transport.open_session()
    channel.settimeout(None)
    # sudo -S: first line = password, remaining stdin = tar stream
    safe = PASS.replace("'", "'\"'\"'")
    channel.exec_command(
        f"echo '{safe}' | sudo -S -p '' bash -lc "
        f"'mkdir -p {remote_dir} && tar -xf - -C {remote_dir}'"
    )
    # NOTE: password already consumed by the echo|sudo pipe above;
    # tar bytes go to sudo's command stdin via the outer SSH channel — WRONG.
    # Use a dedicated approach: write password via -S on a wrapper that reads tar from FD 3,
    # or stage under /var/tmp as the SSH user.
    channel.close()

    stage = f"/var/tmp/baxtep_{label}_{os.getpid()}"
    safe = PASS.replace("'", "'\"'\"'")
    sudo = f"echo '{safe}' | sudo -S -p ''"
    # clean stage owned by admin for extract
    ssh_run(
        client,
        f"{sudo} bash -lc 'rm -rf {stage}; mkdir -p {stage}; chown {USER}:{USER} {stage}; chmod 755 {stage}'",
    )

    channel = transport.open_session()
    channel.settimeout(None)
    channel.exec_command(f"tar -xf - -C {stage}")

    tar_cmd = ["tar", "-cf", "-", "-C", local_cwd]
    for ex in excludes:
        tar_cmd.append(f"--exclude={ex}")
    tar_cmd.append(".")

    print(f"[{label}] streaming → {HOST}:{stage} excludes={excludes}", flush=True)
    t0 = time.time()
    proc = subprocess.Popen(tar_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdout is not None
    sent = 0
    last = t0
    while True:
        chunk = proc.stdout.read(1024 * 1024)
        if not chunk:
            break
        channel.sendall(chunk)
        sent += len(chunk)
        now = time.time()
        if now - last >= 10:
            mb = sent / 1e6
            rate = mb / max(now - t0, 1)
            print(f"  [{label}] {mb:.0f} MB ({rate:.1f} MB/s)", flush=True)
            last = now
    channel.shutdown_write()
    tar_err = proc.stderr.read().decode("utf-8", "replace") if proc.stderr else ""
    proc.wait(timeout=120)
    while not channel.exit_status_ready():
        if channel.recv_ready():
            channel.recv(65536)
        if channel.recv_stderr_ready():
            sys.stderr.write(channel.recv_stderr(65536).decode("utf-8", "replace"))
        time.sleep(0.2)
    remote_code = channel.recv_exit_status()
    remote_err = ""
    while channel.recv_stderr_ready():
        remote_err += channel.recv_stderr(65536).decode("utf-8", "replace")
    channel.close()
    elapsed = time.time() - t0
    print(
        f"[{label}] done local={proc.returncode} remote={remote_code} "
        f"{sent/1e6:.0f} MB in {elapsed:.0f}s",
        flush=True,
    )
    if tar_err.strip():
        print(f"[{label}] tar stderr:", tar_err[:1500])
    if remote_err.strip():
        print(f"[{label}] remote stderr:", remote_err[:1500])
    if proc.returncode or remote_code:
        return proc.returncode or remote_code

    # merge stage → destination as root, then leave ownership fix to finalize_perms
    code, out, err = ssh_run(
        client,
        f"{sudo} bash -lc 'mkdir -p {remote_dir}; cp -a {stage}/. {remote_dir}/; rm -rf {stage}'",
        timeout=600,
    )
    if out.strip():
        print(out)
    if code != 0:
        print("merge failed", err[:1500])
        return code
    return 0


def finalize_perms(client: paramiko.SSHClient, path: str) -> int:
    safe = PASS.replace("'", "'\"'\"'")
    sudo = f"echo '{safe}' | sudo -S -p ''"
    cmd = f"""{sudo} bash -lc '
set -euo pipefail
mkdir -p {path}
rm -rf {path}/temp
chown -R baxtep_tko:baxtep_tko {path}
find {path} -type d -exec chmod u+rwx,g+rx,o-rwx {{}} +
find {path} -type f -exec chmod u+rw,g+r,o-rwx {{}} +
chown baxtep_tko:baxtep_tko /home/baxtep_tko
chmod u+rwx /home/baxtep_tko
stat -c "owner=%U:%G mode=%a path=%n" {path}
ls -la {path} | head -30
echo files=$(find {path} -maxdepth 1 -type f | wc -l)
sudo -u baxtep_tko bash -lc "echo ok > {path}/.write_test && rm -f {path}/.write_test && echo write_ok"
'"""
    code, out, err = ssh_run(client, cmd, timeout=600)
    print(out)
    for line in err.splitlines():
        if "password" not in line.lower() and line.strip():
            print("ERR:", line)
    return code


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "mode",
        choices=("mains", "data", "all"),
        help="mains=without data/temp; data=only data/; all=both",
    )
    args = ap.parse_args()
    if not PASS:
        print("SYSTEMA_PASS required", file=sys.stderr)
        return 2
    if not os.path.isdir(LOCAL):
        print(f"missing {LOCAL}", file=sys.stderr)
        return 2

    safe = PASS.replace("'", "'\"'\"'")
    sudo = f"echo '{safe}' | sudo -S -p ''"

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        HOST,
        username=USER,
        password=PASS,
        timeout=30,
        allow_agent=False,
        look_for_keys=False,
        banner_timeout=60,
    )

    # cleanup partial stage from previous attempt
    ssh_run(client, f"{sudo} bash -lc 'rm -rf {STAGE}; mkdir -p {REMOTE}; chmod 777 {REMOTE} 2>/dev/null || true'")
    # staging extract as root into REMOTE (avoid leaving admin ownership)
    ssh_run(
        client,
        f"{sudo} bash -lc 'mkdir -p {REMOTE}; chown root:root {REMOTE}; chmod 755 {REMOTE}'",
    )

    rc = 0
    if args.mode in ("mains", "all"):
        rc = stream_tar(
            client,
            LOCAL,
            REMOTE,
            excludes=["temp", "./temp", "data", "./data"],
            label="mains",
        )
        if rc != 0:
            client.close()
            return rc
        rc = finalize_perms(client, REMOTE)
        if rc != 0:
            client.close()
            return rc
        print("=== MAINS OK ===", flush=True)

    if args.mode in ("data", "all"):
        data_local = os.path.join(LOCAL, "data")
        if not os.path.isdir(data_local):
            print("no local data/ — skip")
        else:
            remote_data = f"{REMOTE}/data"
            ssh_run(
                client,
                f"{sudo} bash -lc 'mkdir -p {remote_data}; chown {USER}:{USER} {remote_data}'",
            )
            rc = stream_tar(
                client,
                data_local,
                remote_data,
                excludes=["temp", "./temp"],
                label="data",
            )
            if rc != 0:
                client.close()
                return rc
            rc = finalize_perms(client, REMOTE)
            if rc != 0:
                client.close()
                return rc
            print("=== DATA OK ===", flush=True)

    client.close()
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
