#!/usr/bin/env python3
"""
perf_benchmark.py

Drives the local PrintArk 13528 WebSocket service to measure real performance:
sequential end-to-end latency and concurrent throughput. Reuses the same raw
WebSocket framing as replay_13528_preview.py, but instead of waiting a fixed
timeout after each request it detects the terminal `notifyTaskResult`
(completeSuccess / completeFailed) to time each task precisely.

IMPORTANT — what the numbers mean:
  * End-to-end wall-clock latency INCLUDES the protocol's hardcoded simulated
    flow delays (0/15/50/85/130/240 ms staged sends). It is NOT pure compute.
  * The true synchronous compute cost is reported by the service itself as
    `realRenderMs` / `realHandleMs` in its event log (added by this project's
    timing instrumentation). Read those from the service stdout/log for the
    real render cost; this script reports the protocol-level latency the web
    page actually observes.

Safety: every request uses a unique requestID (PERF_<i>_<ms>) to bypass the
10-minute physical-print dedupe. Run the service with --print-dry-run true so
no real `lpr` is ever submitted.

Usage:
    rtk python3 scripts/perf_benchmark.py --mode sequential --count 50
    rtk python3 scripts/perf_benchmark.py --mode concurrent --levels 1,8,32,64
    rtk python3 scripts/perf_benchmark.py --mode both --count 50 --levels 1,8,32,64

Exit codes:
    0 - benchmark completed (results written)
    1 - connection / payload error
"""

import argparse
import asyncio
import base64
import json
import os
import socket
import statistics
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------
DEFAULT_SETCONFIG = Path("captures/probe_results/13528_setPrinterConfig_BF4CB536.json")
DEFAULT_PRINT = Path("captures/probe_results/13528_print_2147849e17822728191162152e1001_79013939670143.json")
DEFAULT_RESULT_DIR = Path("captures/perf_results")
WS_URL = "ws://127.0.0.1:13528/"
TERMINAL_CMD = "notifyTaskResult"
TERMINAL_STATUSES = {"completeSuccess", "completeFailed"}
# A single task's full flow is bounded by the simulated delays (~240ms tail);
# 5s is a generous per-task ceiling so a hung task can't stall the whole run.
PER_TASK_TIMEOUT = 5.0


# ---------------------------------------------------------------------------
# payload helpers
# ---------------------------------------------------------------------------
def load_payload(path: Path, description: str) -> dict:
    if not path.exists():
        print(f"[FAIL] {description} file not found: {path}")
        sys.exit(1)
    return json.loads(path.read_text())


def build_print_request(template: dict, index: int, preview: bool) -> dict:
    """Deep-copy the captured print payload with a unique requestID/taskID."""
    out = json.loads(json.dumps(template))
    rid = f"PERF_{index}_{int(time.time() * 1000)}_{os.urandom(2).hex()}"
    out["requestID"] = rid
    task = out.setdefault("task", {})
    task["taskID"] = rid
    task["preview"] = preview
    return out, rid


# ---------------------------------------------------------------------------
# low-level websocket (sync, no third-party deps) — mirrors replay script
# ---------------------------------------------------------------------------
def parse_ws_url(url: str) -> tuple[str, int]:
    if not url.startswith("ws://"):
        raise ValueError("only ws:// URLs are supported")
    remainder = url[5:].split("/", 1)[0]
    if ":" in remainder:
        host, port_text = remainder.rsplit(":", 1)
        return host, int(port_text)
    return remainder, 80


def ws_connect(host: str, port: int, timeout: float) -> socket.socket:
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(timeout)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET / HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode("ascii"))
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("socket closed during handshake")
        data += chunk
    if b"101 Switching Protocols" not in data:
        raise ConnectionError(f"handshake failed: {data!r}")
    return sock


def ws_send_text(sock: socket.socket, text: str) -> None:
    payload = text.encode("utf-8")
    header = bytearray([0x81])
    mask_bit = 0x80
    length = len(payload)
    if length < 126:
        header.append(mask_bit | length)
    elif length < (1 << 16):
        header.append(mask_bit | 126)
        header.extend(length.to_bytes(2, "big"))
    else:
        header.append(mask_bit | 127)
        header.extend(length.to_bytes(8, "big"))
    mask = os.urandom(4)
    header.extend(mask)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(header) + masked)


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("socket closed unexpectedly")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def ws_recv_json(sock: socket.socket, timeout: float) -> dict:
    sock.settimeout(timeout)
    first_two = _recv_exact(sock, 2)
    opcode = first_two[0] & 0x0F
    masked = bool(first_two[1] & 0x80)
    length = first_two[1] & 0x7F
    if length == 126:
        length = int.from_bytes(_recv_exact(sock, 2), "big")
    elif length == 127:
        length = int.from_bytes(_recv_exact(sock, 8), "big")
    mask = _recv_exact(sock, 4) if masked else b""
    payload = _recv_exact(sock, length)
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    if opcode == 0x8:
        raise ConnectionError("websocket closed by server")
    if opcode != 0x1:
        raise ConnectionError(f"unexpected opcode: {opcode}")
    return json.loads(payload.decode("utf-8"))


def ws_close(sock: socket.socket) -> None:
    try:
        sock.sendall(b"\x88\x00")
    except Exception:
        pass
    sock.close()


# ---------------------------------------------------------------------------
# single task timing
# ---------------------------------------------------------------------------
def run_one_task(sock: socket.socket, print_req: dict, rid: str) -> dict:
    """Send one print request, time until the terminal notifyTaskResult.

    Returns {ok, latency_ms, message_count, terminal_status}.
    """
    t0 = time.monotonic()
    ws_send_text(sock, json.dumps(print_req, ensure_ascii=False))
    message_count = 0
    terminal_status = None
    while True:
        msg = ws_recv_json(sock, PER_TASK_TIMEOUT)
        message_count += 1
        if msg.get("cmd") == TERMINAL_CMD and msg.get("status") in TERMINAL_STATUSES:
            terminal_status = msg.get("status")
            break
        # immediate failure path (empty docs etc.)
        if msg.get("cmd") == "print" and msg.get("status") == "failed":
            terminal_status = "failed"
            break
    latency_ms = (time.monotonic() - t0) * 1000
    return {
        "ok": terminal_status == "completeSuccess",
        "latency_ms": round(latency_ms, 2),
        "message_count": message_count,
        "terminal_status": terminal_status,
        "requestID": rid,
    }


def send_setconfig(sock: socket.socket, setconfig: dict) -> None:
    ws_send_text(sock, json.dumps(setconfig, ensure_ascii=False))
    ws_recv_json(sock, PER_TASK_TIMEOUT)  # consume setPrinterConfig response


def percentiles(values: list[float]) -> dict:
    if not values:
        return {}
    ordered = sorted(values)

    def pct(p: float) -> float:
        if len(ordered) == 1:
            return round(ordered[0], 2)
        k = (len(ordered) - 1) * p
        lo = int(k)
        hi = min(lo + 1, len(ordered) - 1)
        return round(ordered[lo] + (ordered[hi] - ordered[lo]) * (k - lo), 2)

    return {
        "min": round(ordered[0], 2),
        "p50": pct(0.50),
        "p95": pct(0.95),
        "p99": pct(0.99),
        "max": round(ordered[-1], 2),
        "mean": round(statistics.fmean(ordered), 2),
    }


# ---------------------------------------------------------------------------
# sequential benchmark
# ---------------------------------------------------------------------------
def bench_sequential(host: str, port: int, setconfig: dict, template: dict, count: int, preview: bool) -> dict:
    print(f"\n[SEQ] Sequential benchmark: {count} requests (preview={preview})")
    latencies = []
    failures = []
    sock = ws_connect(host, port, PER_TASK_TIMEOUT)
    try:
        send_setconfig(sock, setconfig)
        for i in range(count):
            print_req, rid = build_print_request(template, i, preview)
            try:
                result = run_one_task(sock, print_req, rid)
            except Exception as e:
                failures.append({"index": i, "error": f"{type(e).__name__}: {e}"})
                continue
            latencies.append(result["latency_ms"])
            if (i + 1) % 10 == 0 or i == count - 1:
                print(f"      {i + 1}/{count} done, last={result['latency_ms']}ms "
                      f"msgs={result['message_count']} status={result['terminal_status']}")
    finally:
        ws_close(sock)
    stats = percentiles(latencies)
    print(f"[SEQ] latency_ms {stats}  failures={len(failures)}")
    return {
        "mode": "sequential",
        "count": count,
        "preview": preview,
        "completed": len(latencies),
        "failures": failures,
        "latency_ms": stats,
        "raw_latencies_ms": latencies,
    }


# ---------------------------------------------------------------------------
# concurrent benchmark
# ---------------------------------------------------------------------------
async def one_connection_task(host: str, port: int, setconfig: dict, template: dict, index: int, preview: bool) -> dict:
    def blocking() -> dict:
        sock = ws_connect(host, port, PER_TASK_TIMEOUT)
        try:
            send_setconfig(sock, setconfig)
            print_req, rid = build_print_request(template, index, preview)
            return run_one_task(sock, print_req, rid)
        finally:
            ws_close(sock)

    return await asyncio.to_thread(blocking)


async def bench_concurrent_level(host: str, port: int, setconfig: dict, template: dict, concurrency: int, preview: bool) -> dict:
    print(f"\n[CONC] Concurrency={concurrency} (preview={preview})")
    t0 = time.monotonic()
    results = await asyncio.gather(
        *[one_connection_task(host, port, setconfig, template, i, preview) for i in range(concurrency)],
        return_exceptions=True,
    )
    wall_ms = (time.monotonic() - t0) * 1000
    latencies = []
    errors = []
    for i, r in enumerate(results):
        if isinstance(r, Exception):
            errors.append({"index": i, "error": f"{type(r).__name__}: {r}"})
        else:
            latencies.append(r["latency_ms"])
    throughput = (len(latencies) / (wall_ms / 1000)) if wall_ms > 0 else 0
    stats = percentiles(latencies)
    print(f"[CONC] wall={round(wall_ms, 2)}ms  throughput={round(throughput, 2)} req/s  "
          f"completed={len(latencies)}/{concurrency}  errors={len(errors)}")
    print(f"[CONC] latency_ms {stats}")
    return {
        "concurrency": concurrency,
        "wall_ms": round(wall_ms, 2),
        "throughput_req_s": round(throughput, 2),
        "completed": len(latencies),
        "errors": errors,
        "latency_ms": stats,
    }


async def bench_concurrent(host: str, port: int, setconfig: dict, template: dict, levels: list[int], preview: bool) -> dict:
    print(f"\n[CONC] Concurrent benchmark: levels={levels}")
    level_results = []
    for level in levels:
        level_results.append(await bench_concurrent_level(host, port, setconfig, template, level, preview))
    return {"mode": "concurrent", "preview": preview, "levels": level_results}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="PrintArk 13528 performance benchmark")
    parser.add_argument("--url", default=WS_URL, help=f"WebSocket URL (default {WS_URL})")
    parser.add_argument("--setconfig", type=Path, default=DEFAULT_SETCONFIG)
    parser.add_argument("--print", type=Path, dest="print_path", default=DEFAULT_PRINT)
    parser.add_argument("--mode", choices=["sequential", "concurrent", "both"], default="both")
    parser.add_argument("--count", type=int, default=50, help="sequential request count")
    parser.add_argument("--levels", default="1,8,32,64", help="comma-separated concurrency levels")
    parser.add_argument("--preview", default="true", help="preview flag true/false (true keeps dry-run safe)")
    args = parser.parse_args()

    preview = args.preview != "false"
    host, port = parse_ws_url(args.url)
    setconfig = load_payload(args.setconfig, "setPrinterConfig")
    template = load_payload(args.print_path, "print")
    if "task" not in template or "documents" not in template.get("task", {}):
        print("[FAIL] print payload missing task.documents")
        return 1
    levels = [int(x) for x in args.levels.split(",") if x.strip()]

    print(f"[PERF] url={args.url} mode={args.mode} preview={preview}")
    print(f"[PERF] NOTE: end-to-end latency includes simulated flow delays; "
          f"read realRenderMs/realHandleMs from the service log for true compute cost.")

    report = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "url": args.url,
        "preview": preview,
        "note": "end-to-end latency includes hardcoded simulated flow delays; "
                "true compute cost is in service log realRenderMs/realHandleMs",
        "sequential": None,
        "concurrent": None,
    }

    try:
        if args.mode in ("sequential", "both"):
            report["sequential"] = bench_sequential(host, port, setconfig, template, args.count, preview)
        if args.mode in ("concurrent", "both"):
            report["concurrent"] = asyncio.run(
                bench_concurrent(host, port, setconfig, template, levels, preview)
            )
    except (ConnectionRefusedError, OSError) as e:
        print(f"[FAIL] Connection error: {e}\n       Is PrintArk running on {args.url}?")
        return 1

    DEFAULT_RESULT_DIR.mkdir(parents=True, exist_ok=True)
    out_file = DEFAULT_RESULT_DIR / f"perf_{args.mode}_{int(time.time())}.json"
    out_file.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"\n[PERF] Saved report to {out_file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
