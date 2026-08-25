"""Remote tests via SSH: one scenario or full suite (test --all).

- run_one_scenario() → python -m deploy <device> test <scenario>
- run_all()         → python -m deploy <device> test --all <duration>

Scenarios live in tests/ on the device; this module only drives them over SSH.
"""
from __future__ import annotations

import json
import re
import signal
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import paramiko  # type: ignore

from . import remote
from .remote import connect, env_creds, quiet_paramiko, reconnect_with_retry, run

TZ = timezone(timedelta(hours=7))
MIN_DURATION_SEC = 300

# Ctrl+C: сначала дождаться конца текущего сценария, повторный — оборвать SSH.
_stop_after_current = False
_force_stop = False
_active_client: paramiko.SSHClient | None = None


def _on_sigint(_signum: int, _frame: object) -> None:
    global _stop_after_current, _force_stop
    if _stop_after_current or _force_stop:
        _force_stop = True
        print(
            "\nCtrl+C: abort now (closing SSH)…",
            flush=True,
        )
        client = _active_client
        if client is not None:
            try:
                client.close()
            except Exception:
                pass
        return
    _stop_after_current = True
    print(
        "\nCtrl+C: finish current test, then stop (Ctrl+C again to abort)…",
        flush=True,
    )

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
    ("outage-dry", ["outage-dry", "{observe}"], {"observe": 120, "timeout_pad": 360}),
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


def ensure_client(
    client: paramiko.SSHClient | None,
    *,
    wait: bool = False,
) -> paramiko.SSHClient:
    if client is not None and _alive(client):
        return client
    if client is not None:
        try:
            client.close()
        except Exception:
            pass
    if wait:
        return reconnect_with_retry()
    return connect(fatal=False)


# Сценарии, которые рвут WAN/VPN — запускаем detached и ждём файл результата
_DETACHED_SCENARIOS = {
    "wan-failover",
    "outage-dry",
    "lte-soft-fail",
    "lte-recover-ladder",
    "lte-apn-firstboot",
}

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
    try:
        client = ensure_client(client, wait=True)
        _, out, _ = run(client, _HEALTH_CMD, use_sudo=True, timeout=40, quiet=True)
    except (OSError, TimeoutError, paramiko.SSHException, EOFError, ConnectionError):
        client = ensure_client(None, wait=True)
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


def _print_verdict(name: str, status: str, note: str = "") -> None:
    """Итог для SUMMARY в конце suite."""
    tag = str(status).upper()
    extra = f" — {note}" if note else ""
    print(f"  {tag:5}  {name}{extra}", flush=True)


_item_line_open = False
_item_line_broken = False
_item_line_meta: tuple[int, int, str] | None = None


def _print_item_start(index: int, total: int, name: str) -> None:
    global _item_line_open, _item_line_broken, _item_line_meta
    _item_line_open = True
    _item_line_broken = False
    _item_line_meta = (index, total, name)
    print(f"[{index}/{total}] {name} ...", flush=True, end="")


def _print_item_finish(
    status: str,
    sec: int,
    note: str = "",
) -> None:
    global _item_line_open, _item_line_broken, _item_line_meta
    tag = str(status).upper()
    detail = ""
    if tag != "PASS" and note:
        short = note.replace("\n", " ").strip()
        if len(short) > 120:
            short = short[:117] + "..."
        detail = f" — {short}"
    # Только хвост — [n/m] name уже напечатан в start (без \r и без второго номера)
    print(f" {tag} ... ({sec}s){detail}", flush=True)
    _item_line_open = False
    _item_line_broken = False
    _item_line_meta = None


def _break_item_line_for_ssh() -> None:
    """Пометить строку теста сломанной (без лишнего переноса в лог)."""
    global _item_line_broken
    if _item_line_open:
        _item_line_broken = True


remote.before_reconnect_log = _break_item_line_for_ssh


def _mark_item_line_broken() -> None:
    """Если в консоль утекло Socket exception mid-line."""
    global _item_line_broken
    if _item_line_open:
        _item_line_broken = True


def _run_detached(
    client: paramiko.SSHClient,
    args: list[str],
    timeout: int,
) -> tuple[paramiko.SSHClient, int, str, str]:
    """Запуск сценария через nohup: SSH может отвалиться (WAN↓), тест на устройстве продолжается."""
    global _active_client
    stamp = int(time.time())
    out_f = f"/tmp/pc-router-suite-{stamp}.out"
    exit_f = f"/tmp/pc-router-suite-{stamp}.exit"
    quoted = " ".join(args)
    root = remote.remote_root()
    starter = (
        f"bash -lc 'rm -f {exit_f} {out_f}; "
        f"nohup bash -c \"bash {root}/tests/run.sh {quoted} >{out_f} 2>&1; "
        f"echo \\$? >{exit_f}\" >/dev/null 2>&1 & echo started'"
    )
    _ = run(client, starter, use_sudo=True, timeout=30, quiet=True)

    deadline = time.time() + timeout + 60
    code = -1
    out = ""
    err = ""
    while time.time() < deadline:
        if _force_stop:
            break
        try:
            client = ensure_client(client, wait=True)
            _active_client = client
            _, probe, _ = run(
                client,
                f"bash -lc 'if test -f {exit_f}; then echo DONE; cat {exit_f}; "
                f"else echo WAIT; fi'",
                use_sudo=True,
                timeout=30,
                quiet=True,
            )
            lines = [ln.strip() for ln in probe.splitlines() if ln.strip()]
            if lines and lines[0] == "DONE":
                try:
                    code = int(lines[1]) if len(lines) > 1 else 1
                except ValueError:
                    code = 1
                _, out, _ = run(
                    client,
                    f"bash -lc 'cat {out_f} 2>/dev/null; rm -f {out_f} {exit_f}'",
                    use_sudo=True,
                    timeout=60,
                    quiet=True,
                )
                return client, code, out, err
        except (OSError, TimeoutError, paramiko.SSHException, EOFError, ConnectionError):
            _mark_item_line_broken()
            try:
                client = reconnect_with_retry()
                _active_client = client
            except ConnectionError:
                time.sleep(5)
                continue
        time.sleep(5)

    # Таймаут / abort — попробуем cleanup и снять хвост лога
    try:
        client = ensure_client(None, wait=True)
        _active_client = client
        _, out, _ = run(
            client,
            f"bash -lc 'tail -n 80 {out_f} 2>/dev/null; "
            f"test -f {exit_f} && cat {exit_f} || echo 124'",
            use_sudo=True,
            timeout=60,
            quiet=True,
        )
        tail_lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
        if tail_lines and tail_lines[-1].isdigit():
            code = int(tail_lines[-1])
        err = "detached timeout" if code < 0 else ""
    except Exception as e:
        err = f"detached wait failed: {type(e).__name__}"
        code = 124
    return client, code, out, err


def _run_suite_item(
    client: paramiko.SSHClient,
    name: str,
    args: list[str],
    timeout: int,
    round_n: int,
    index: int,
    total: int,
) -> tuple[paramiko.SSHClient, dict[str, object]]:
    global _active_client
    _print_item_start(index, total, name)
    try:
        client = ensure_client(client, wait=True)
    except (OSError, TimeoutError, paramiko.SSHException, ConnectionError) as e:
        note = f"SSH unavailable: {type(e).__name__}"
        _print_item_finish("FAIL", 0, note)
        return client if client else connect(fatal=False), {
            "name": name,
            "status": "FAIL",
            "exit": -1,
            "seconds": 0,
            "round": round_n,
            "finished": now_local().isoformat(),
            "note": note,
        }
    _active_client = client
    try:
        _ = run(client, _CLEANUP_CMD, use_sudo=True, timeout=60, quiet=True)
    except (OSError, paramiko.SSHException, EOFError):
        try:
            client = ensure_client(None, wait=True)
        except Exception:
            pass
        _active_client = client

    t0 = time.time()
    try:
        _active_client = client
        if name in _DETACHED_SCENARIOS:
            client, code, out, err = _run_detached(client, args, timeout)
        else:
            quoted = " ".join(args)
            code, out, err = run(
                client,
                f"bash {remote.remote_root()}/tests/run.sh {quoted}",
                use_sudo=True,
                timeout=timeout,
                quiet=True,
            )
    except KeyboardInterrupt:
        sec = int(time.time() - t0)
        _print_item_finish("ABORT", sec, "Ctrl+C")
        return client, {
            "name": name,
            "status": "ABORT",
            "exit": 130,
            "seconds": sec,
            "round": round_n,
            "finished": now_local().isoformat(),
            "note": "Ctrl+C",
        }
    except (OSError, TimeoutError, paramiko.SSHException, EOFError, ConnectionError) as e:
        sec = int(time.time() - t0)
        if _force_stop:
            _print_item_finish("ABORT", sec, "Ctrl+C abort")
            return client, {
                "name": name,
                "status": "ABORT",
                "exit": 130,
                "seconds": sec,
                "round": round_n,
                "finished": now_local().isoformat(),
                "note": "Ctrl+C abort",
            }
        try:
            client = reconnect_with_retry()
            _active_client = client
            _ = run(client, _CLEANUP_CMD, use_sudo=True, timeout=60, quiet=True)
        except Exception:
            try:
                client = reconnect_with_retry()
                _active_client = client
            except Exception:
                pass
        note = f"SSH lost: {type(e).__name__}"
        _mark_item_line_broken()
        _print_item_finish("FAIL", sec, note)
        result: dict[str, object] = {
            "name": name,
            "status": "FAIL",
            "exit": -1,
            "seconds": sec,
            "round": round_n,
            "finished": now_local().isoformat(),
            "note": note,
        }
        return client, result

    sec = int(time.time() - t0)
    text = f"{out or ''}\n{err or ''}"
    status = "PASS" if code == 0 else "FAIL"
    if code == 124:
        status = "FAIL"
        note = _pass_note(text) or (err[:120] if err else "timeout")
    else:
        note = _pass_note(text) or (err[:120] if err else "")
    # Если в консоль попал Socket exception mid-line — считаем строку сломанной
    if "Socket exception" in text or "10054" in text:
        _mark_item_line_broken()
    _print_item_finish(status, sec, note)
    result_ok: dict[str, object] = {
        "name": name,
        "status": status,
        "exit": code,
        "seconds": sec,
        "round": round_n,
        "finished": now_local().isoformat(),
        "note": note,
    }
    return client, result_ok


def run_all(duration_sec: int) -> int:
    """Cycle suite scenarios until duration elapses; laconic console log."""
    global _stop_after_current, _force_stop, _active_client
    quiet_paramiko()
    _stop_after_current = False
    _force_stop = False
    prev_handler = signal.signal(signal.SIGINT, _on_sigint)

    scenarios = scale_scenarios(duration_sec)
    deadline = time.time() + duration_sec
    local, remote_report = report_paths()
    host, _, _ = env_creds()
    client = connect()
    _active_client = client
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
    print("(Ctrl+C: finish current test then stop)", flush=True)

    round_n = 0
    total = len(scenarios)
    try:
        while True:
            if _stop_after_current or _force_stop:
                print("stop: interrupt requested", flush=True)
                break
            remaining = deadline - time.time()
            if remaining < 90:
                print(f"stop: {remaining:.0f}s left", flush=True)
                break
            round_n += 1
            data["rounds"] = round_n
            if round_n > 1:
                print(f"— round {round_n} —", flush=True)
            round_pass = 0
            round_done = 0
            for i, (name, args, timeout) in enumerate(scenarios, 1):
                if _stop_after_current or _force_stop:
                    print("stop: interrupt requested", flush=True)
                    break
                remaining = deadline - time.time()
                if remaining < min(timeout, 90):
                    print(f"stop: {remaining:.0f}s left, skip {name}+", flush=True)
                    break
                try:
                    _active_client = client
                    client, result = _run_suite_item(
                        client,
                        name,
                        args,
                        min(timeout, int(remaining) + 30),
                        round_n,
                        i,
                        total,
                    )
                except KeyboardInterrupt:
                    _stop_after_current = True
                    result = {
                        "name": name,
                        "status": "ABORT",
                        "exit": 130,
                        "seconds": 0,
                        "round": round_n,
                        "finished": now_local().isoformat(),
                        "note": "Ctrl+C",
                    }
                    _print_item_start(i, total, name)
                    _print_item_finish("ABORT", 0, "Ctrl+C")
                except Exception as e:
                    note = str(e)[:200]
                    result = {
                        "name": name,
                        "status": "ERROR",
                        "exit": -1,
                        "seconds": 0,
                        "round": round_n,
                        "finished": now_local().isoformat(),
                        "note": note,
                    }
                    _print_item_start(i, total, name)
                    _print_item_finish("ERROR", 0, note)
                    try:
                        client = ensure_client(None, wait=True)
                    except Exception:
                        pass
                    _active_client = client
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
                round_done += 1
                if str(result["status"]) == "PASS":
                    round_pass += 1
                try:
                    client = ensure_client(client, wait=True)
                    _active_client = client
                    sftp = client.open_sftp()
                    _ = sftp.put(str(local), remote_report)
                    _ = sftp.put(
                        str(local.with_suffix(".md")),
                        remote_report.replace(".json", ".md"),
                    )
                    sftp.close()
                except Exception:
                    pass
                if _stop_after_current or _force_stop:
                    print("stop: after current test", flush=True)
                    break
                time.sleep(3)
            if round_done:
                print(
                    f"round {round_n}: {round_pass}/{round_done} PASS"
                    + (f" (of {total})" if round_done < total else ""),
                    flush=True,
                )
            else:
                break
            if _stop_after_current or _force_stop:
                break
            # полный раунд — продолжаем while; частичный (stop по времени) — выход
            if round_done < total:
                break
    finally:
        signal.signal(signal.SIGINT, prev_handler)
        _active_client = None
        try:
            _ = run(client, _CLEANUP_CMD, use_sudo=True, timeout=60, quiet=True)
        except Exception:
            pass

    if _stop_after_current or _force_stop:
        print("suite stopped by Ctrl+C", flush=True)

    print("", flush=True)
    print("========== SUMMARY ==========", flush=True)
    summary_raw = data.get("summary") or {}
    summary: dict[str, object] = dict(summary_raw) if isinstance(summary_raw, dict) else {}
    n_pass = sum(1 for v in summary.values() if v == "PASS")
    print(f"  {n_pass}/{len(summary)} PASS", flush=True)
    for k, v in summary.items():
        _print_verdict(str(k), str(v))
    print("==============================", flush=True)
    print(f"report: {local}", flush=True)
    try:
        client.close()
    except Exception:
        pass
    if not data["runs"]:
        return 2
    if _force_stop:
        return 130
    fails = [k for k, v in summary.items() if v not in ("PASS", "PENDING")]
    return 1 if fails else 0