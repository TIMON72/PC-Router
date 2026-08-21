"""Remote tests via SSH: one scenario or full suite (test --all).

- run_one_scenario() → python -m deploy <device> test <scenario>
- run_all()         → python -m deploy <device> test --all <duration>

Scenarios live in tests/ on the device; this module only drives them over SSH.
"""
from __future__ import annotations

import json
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import paramiko  # type: ignore

from . import remote
from .remote import connect, env_creds, run

TZ = timezone(timedelta(hours=7))
MIN_DURATION_SEC = 300

DURATION_PRESETS: dict[str, int] = {
    "300": 300,
    "5m": 300,
    "3600": 3600,
    "1h": 3600,
    "7200": 7200,
    "2h": 7200,
    "14400": 14400,
    "4h": 14400,
    "21600": 21600,
    "6h": 21600,
    "28800": 28800,
    "8h": 28800,
    "43200": 43200,
    "12h": 43200,
    "86400": 86400,
    "24h": 86400,
    "1d": 86400,
}

# (name, run.sh args with {observe}/{dwell}, defaults)
_SUITE: list[tuple[str, list[str], dict[str, int]]] = [
    ("recover-selftest", ["recover-selftest"], {"timeout": 120}),
    ("outage-dry", ["outage-dry", "{observe}"], {"observe": 120, "timeout_pad": 240}),
    (
        "wan-failover",
        ["wan-failover", "{observe}", "{dwell}"],
        {"observe": 120, "dwell": 40, "timeout_pad": 280},
    ),
    ("lte-soft-fail", ["lte-soft-fail", "{observe}"], {"observe": 120, "timeout_pad": 180}),
    (
        "lte-recover-ladder",
        ["lte-recover-ladder", "{observe}"],
        {"observe": 200, "timeout_pad": 400},
    ),
    (
        "lte-apn-firstboot",
        ["lte-apn-firstboot", "{observe}"],
        {"observe": 180, "timeout_pad": 320},
    ),
]

_SHORT = {"snap", "events", "list", "help", "recover-selftest", "recover-lib"}
_LONG = {
    "lte-recover-ladder",
    "lte-ladder",
    "recover-ladder",
    "lte-apn-firstboot",
    "apn-firstboot",
}


def parse_duration(token: str) -> int:
    t = token.strip().lower()
    if t in DURATION_PRESETS:
        sec = DURATION_PRESETS[t]
    elif re.fullmatch(r"\d+", t):
        sec = int(t)
    elif m := re.fullmatch(r"(\d+)\s*s(ec(onds?)?)?", t):
        sec = int(m.group(1))
    elif m := re.fullmatch(r"(\d+)\s*m(in(utes?)?)?", t):
        sec = int(m.group(1)) * 60
    elif m := re.fullmatch(r"(\d+)\s*h(ours?)?", t):
        sec = int(m.group(1)) * 3600
    elif m := re.fullmatch(r"(\d+)\s*d(ays?)?", t):
        sec = int(m.group(1)) * 86400
    else:
        known = ", ".join(sorted(DURATION_PRESETS, key=lambda k: DURATION_PRESETS[k]))
        print(f"Bad duration {token!r}. Use seconds or presets: {known}", file=sys.stderr)
        raise SystemExit(2)
    if sec < MIN_DURATION_SEC:
        print(f"Duration {sec}s < minimum {MIN_DURATION_SEC}s", file=sys.stderr)
        raise SystemExit(2)
    return sec


def _one_pass_budget(observe_scale: float = 1.0) -> int:
    total = 0
    for _name, _tmpl, meta in _SUITE:
        if "observe" not in meta:
            total += meta["timeout"]
            continue
        obs = max(60, int(meta["observe"] * observe_scale))
        dwell = (
            max(20, int(meta.get("dwell", 0) * observe_scale)) if "dwell" in meta else 0
        )
        total += obs + dwell + meta.get("timeout_pad", 120) + 15
    return total


def scale_scenarios(duration_sec: int) -> list[tuple[str, list[str], int]]:
    scale = 1.0
    base_budget = _one_pass_budget(1.0)
    if duration_sec < base_budget:
        scale = max(0.5, duration_sec / base_budget)

    out: list[tuple[str, list[str], int]] = []
    for name, tmpl, meta in _SUITE:
        if "observe" not in meta:
            out.append((name, list(tmpl), meta["timeout"]))
            continue
        obs = max(60, int(meta["observe"] * scale))
        dwell = max(20, int(meta["dwell"] * scale)) if "dwell" in meta else None
        args: list[str] = []
        for part in tmpl:
            if part == "{observe}":
                args.append(str(obs))
            elif part == "{dwell}":
                args.append(str(dwell if dwell is not None else 0))
            else:
                args.append(part)
        timeout = obs + (dwell or 0) + meta.get("timeout_pad", 120)
        out.append((name, args, timeout))
    return out


def now_local() -> datetime:
    return datetime.now(TZ)


def report_paths() -> tuple[Path, str]:
    host, _, _ = env_creds()
    tag = remote.device_name() or host.replace(".", "-")
    local = Path(__file__).resolve().parents[1] / "tmp" / f"suite-{tag}-report.json"
    local.parent.mkdir(parents=True, exist_ok=True)
    return local, f"{remote.remote_root()}/tmp/suite-report.json"


def save_report(path: Path, data: dict[str, object]) -> None:
    data["updated"] = now_local().isoformat()
    _ = path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = [
        f"# Suite {data.get('device_name') or data.get('host')}",
        "",
        f"- duration: {data.get('duration_sec')}s",
        f"- started: {data.get('started')}",
        f"- updated: {data.get('updated')}",
        f"- rounds: {data.get('rounds')}",
        "",
        "## Results",
        "",
    ]
    runs_raw = data.get("runs") or []
    runs: list[dict[str, object]] = (
        list(runs_raw) if isinstance(runs_raw, list) else []
    )
    for r in runs:
        note = f" — {r['note']}" if r.get("note") else ""
        lines.append(
            f"- `{r['status']}` {r['name']} ({r.get('seconds')}s, round {r.get('round')}){note}"
        )
    lines.append("")
    summ_raw = data.get("summary") or {}
    summ: dict[str, object] = dict(summ_raw) if isinstance(summ_raw, dict) else {}
    if summ:
        lines.extend(["## Summary", ""])
        for k, v in summ.items():
            lines.append(f"- {k}: **{v}**")
        lines.append("")
    _ = path.with_suffix(".md").write_text("\n".join(lines), encoding="utf-8")


def _alive(client: paramiko.SSHClient) -> bool:
    try:
        t = client.get_transport()
        return bool(t and t.is_active())
    except Exception:
        return False


def ensure_client(client: paramiko.SSHClient | None) -> paramiko.SSHClient:
    if client is not None and _alive(client):
        return client
    if client is not None:
        try:
            client.close()
        except Exception:
            pass
        print("SSH reconnect…", flush=True)
    return connect()


_HEALTH_CMD = (
    "bash -lc 'systemctl is-active lte lte-failover network-failsafe.timer; "
    "ping -c1 -W2 8.8.8.8 >/dev/null && echo NET_OK || echo NET_FAIL'"
)

_CLEANUP_CMD = (
    "bash -lc 'rm -f /tmp/hold-wan-down /run/systema-router/test.env; "
    "iptables -D OUTPUT -o ppp0 -p icmp -j DROP 2>/dev/null || true; "
    "iptables -D INPUT -i ppp0 -p icmp -j DROP 2>/dev/null || true; "
    "ip link set enp3s0 up 2>/dev/null || true; networkctl up enp3s0 2>/dev/null || true'"
)


def health(client: paramiko.SSHClient) -> tuple[paramiko.SSHClient, str]:
    client = ensure_client(client)
    try:
        _, out, _ = run(client, _HEALTH_CMD, use_sudo=True, timeout=40, quiet=True)
    except (OSError, paramiko.SSHException, EOFError):
        client = ensure_client(None)
        _, out, _ = run(client, _HEALTH_CMD, use_sudo=True, timeout=40, quiet=True)
    parts = [p.strip() for p in out.splitlines() if p.strip()]
    svc = ",".join(parts[:3]) if len(parts) >= 3 else ",".join(parts)
    net = parts[-1] if parts else "?"
    return client, f"svc=[{svc}] {net}"


def _pass_note(text: str) -> str:
    for line in text.splitlines()[::-1]:
        s = line.strip()
        if s.startswith("PASS") or s.startswith("FAIL") or s.startswith("WARN"):
            return s[:200]
    return ""


def run_one_scenario(args: list[str]) -> int:
    """Single remote tests/run.sh invocation (verbose)."""
    if "--" in args:
        i = args.index("--")
        cmd_args = args[:i] + args[i + 1 :]
    else:
        cmd_args = args
    if not cmd_args:
        print("usage: python -m deploy <device> test <scenario> [-- args...]")
        return 2

    quoted = " ".join(f"'{a}'" if " " in a else a for a in cmd_args)
    remote_cmd = f"bash {remote.remote_root()}/tests/run.sh {quoted}"
    timeout = 600
    if cmd_args[0] in _SHORT:
        timeout = 90
    if cmd_args[0] in _LONG:
        timeout = 900

    client = connect()
    code, _, _ = run(client, remote_cmd, use_sudo=True, timeout=timeout)
    client.close()
    return code


def _run_suite_item(
    client: paramiko.SSHClient,
    name: str,
    args: list[str],
    timeout: int,
    round_n: int,
    index: int,
    total: int,
) -> tuple[paramiko.SSHClient, dict[str, object]]:
    print(f"[{index}/{total}] {name} …", flush=True, end="")
    client = ensure_client(client)
    try:
        _ = run(client, _CLEANUP_CMD, use_sudo=True, timeout=60, quiet=True)
    except (OSError, paramiko.SSHException, EOFError):
        client = ensure_client(None)

    t0 = time.time()
    quoted = " ".join(args)
    try:
        code, out, err = run(
            client,
            f"bash {remote.remote_root()}/tests/run.sh {quoted}",
            use_sudo=True,
            timeout=timeout,
            quiet=True,
        )
    except (OSError, paramiko.SSHException, EOFError) as e:
        sec = int(time.time() - t0)
        result: dict[str, object] = {
            "name": name,
            "status": "ERROR",
            "exit": -1,
            "seconds": sec,
            "round": round_n,
            "finished": now_local().isoformat(),
            "note": f"SSH lost: {type(e).__name__}",
        }
        print(f" ERROR ({sec}s) — {result['note']}", flush=True)
        return ensure_client(None), result

    sec = int(time.time() - t0)
    text = f"{out or ''}\n{err or ''}"
    status = "PASS" if code == 0 else "FAIL"
    note = _pass_note(text)
    suffix = f" — {note}" if note else ""
    print(f" {status} ({sec}s){suffix}", flush=True)
    return client, {
        "name": name,
        "status": status,
        "exit": code,
        "seconds": sec,
        "round": round_n,
        "finished": now_local().isoformat(),
        "note": note,
    }


def run_all(duration_sec: int) -> int:
    """Cycle suite scenarios until duration elapses; laconic console log."""
    scenarios = scale_scenarios(duration_sec)
    deadline = time.time() + duration_sec
    local, remote_report = report_paths()
    host, _, _ = env_creds()
    client = connect()
    data: dict[str, object] = {
        "host": host,
        "device_name": remote.device_name(),
        "duration_sec": duration_sec,
        "started": now_local().isoformat(),
        "runs": [],
        "summary": {n: "PENDING" for n, _, _ in scenarios},
        "rounds": 0,
    }
    save_report(local, data)
    print(
        f"suite {remote.device_name() or host}  duration={duration_sec}s "
        f"({duration_sec / 3600:.1f}h)  scenarios={len(scenarios)}",
        flush=True,
    )
    client, h = health(client)
    print(f"health: {h}", flush=True)

    round_n = 0
    total = len(scenarios)
    while True:
        remaining = deadline - time.time()
        if remaining < 90:
            print(f"stop: {remaining:.0f}s left", flush=True)
            break
        round_n += 1
        data["rounds"] = round_n
        if round_n > 1:
            print(f"— round {round_n} —", flush=True)
        for i, (name, args, timeout) in enumerate(scenarios, 1):
            remaining = deadline - time.time()
            if remaining < min(timeout, 90):
                print(f"stop: {remaining:.0f}s left, skip {name}+", flush=True)
                break
            try:
                client, result = _run_suite_item(
                    client,
                    name,
                    args,
                    min(timeout, int(remaining) + 30),
                    round_n,
                    i,
                    total,
                )
            except Exception as e:
                result = {
                    "name": name,
                    "status": "ERROR",
                    "exit": -1,
                    "seconds": 0,
                    "round": round_n,
                    "finished": now_local().isoformat(),
                    "note": str(e)[:200],
                }
                print(f"[{i}/{total}] {name} … ERROR — {result['note']}", flush=True)
                client = ensure_client(None)
            entry: dict[str, object] = {
                "name": result["name"],
                "status": result["status"],
                "exit": result["exit"],
                "seconds": result["seconds"],
                "round": result["round"],
                "finished": result["finished"],
                "note": result.get("note", ""),
            }
            runs_raw = data["runs"]
            runs: list[dict[str, object]] = (
                list(runs_raw) if isinstance(runs_raw, list) else []
            )
            runs.append(entry)
            data["runs"] = runs
            data["summary"] = {
                n: next(
                    (
                        str(r["status"])
                        for r in reversed(runs)
                        if r.get("name") == n
                    ),
                    "PENDING",
                )
                for n, _, _ in scenarios
            }
            save_report(local, data)
            try:
                client = ensure_client(client)
                sftp = client.open_sftp()
                _ = sftp.put(str(local), remote_report)
                _ = sftp.put(
                    str(local.with_suffix(".md")),
                    remote_report.replace(".json", ".md"),
                )
                sftp.close()
            except Exception:
                pass
            client, h = health(client)
            print(f"      health: {h}", flush=True)
            time.sleep(3)
        else:
            continue
        break

    print("", flush=True)
    print("SUMMARY", flush=True)
    summary_raw = data.get("summary") or {}
    summary: dict[str, object] = dict(summary_raw) if isinstance(summary_raw, dict) else {}
    for k, v in summary.items():
        print(f"  {str(v):5}  {k}", flush=True)
    print(f"report: {local}", flush=True)
    try:
        client.close()
    except Exception:
        pass
    if not data["runs"]:
        return 2
    fails = [k for k, v in summary.items() if v != "PASS"]
    return 1 if fails else 0
