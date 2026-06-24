#!/usr/bin/env python3
"""
replay_13528_preview.py

Connects to the local Cainiao 13528 WebSocket service and replays a captured
print request against several protocol branches.

Usage:
    rtk python3 scripts/replay_13528_preview.py
    rtk python3 scripts/replay_13528_preview.py --case preview-false
    rtk python3 scripts/replay_13528_preview.py --case empty-documents
    rtk python3 scripts/replay_13528_preview.py --case decrypt-failure
    rtk python3 scripts/replay_13528_preview.py --url ws://127.0.0.1:13528/
    rtk python3 scripts/replay_13528_preview.py --setconfig path.json --print path.json

Exit codes:
    0  - flow verified
    1  - connection / payload error
    2  - flow assertion failed
"""

import asyncio
import base64
import hashlib
import json
import os
import socket
import ssl
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------
DEFAULT_SETCONFIG = Path("captures/probe_results/13528_setPrinterConfig_BF4CB536.json")
DEFAULT_PRINT = Path("captures/probe_results/13528_print_2147849e17822728191162152e1001_79013939670143.json")
DEFAULT_RESULT_DIR = Path("captures/replay_results")
WS_URL = "ws://127.0.0.1:13528/"
TIMEOUT = 10.0  # seconds to wait after last message before concluding

SCENARIOS = {
    "preview": {
        "label": "preview=true",
        "expected_flow": [
            {"cmd": "notifyTaskResult", "status": "initial"},
            {"cmd": "print", "status": "success", "errorCode": 0},
            {"cmd": "notifyDocResult", "status": "rendered"},
            {"cmd": "notifyDocResult", "status": "printed"},
            {"cmd": "print", "status": "success", "has_previewURL": True},
            {"cmd": "notifyTaskResult", "status": "completeSuccess"},
        ],
        "configure": lambda payload: set_preview_flag(payload, True),
    },
    "preview-false": {
        "label": "preview=false",
        "expected_flow": [
            {"cmd": "notifyTaskResult", "status": "initial"},
            {"cmd": "print", "status": "success", "errorCode": 0},
            {"cmd": "notifyDocResult", "status": "rendered"},
            {"cmd": "notifyDocResult", "status": "printed"},
            {
                "cmd": "notifyPrintResult",
                "status": 0,
                "taskStatus": "printed",
                "no_previewURL": True,
            },
            {"cmd": "notifyTaskResult", "status": "completeSuccess"},
        ],
        "configure": lambda payload: set_preview_flag(payload, False),
    },
    "empty-documents": {
        "label": "document not found",
        "expected_flow": [
            {"cmd": "print", "status": "failed", "errorCode": 11, "msg": "document not found"},
        ],
        "configure": lambda payload: clear_documents(payload),
    },
    "decrypt-failure": {
        "label": "decrypt failure",
        "expected_flow": [
            {"cmd": "notifyTaskResult", "status": "initial"},
            {"cmd": "print", "status": "success", "errorCode": 0},
            {
                "cmd": "notifyDocResult",
                "status": "rendered",
                "code": 40,
                "detail": "Unknown encryption type.",
            },
        ],
        "configure": lambda payload: set_preview_flag(payload, True),
    },
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def load_payload(path: Path, description: str):
    if not path.exists():
        print(f"[FAIL] {description} file not found: {path}")
        sys.exit(1)
    obj = json.loads(path.read_text())
    return obj


def make_request_id() -> str:
    """Generate a unique requestID for traceability."""
    ts = int(time.time() * 1000)
    return f"GA_REPLAY_{ts}"


def replace_request_ids(obj: dict, new_rid: str) -> dict:
    """Replace requestID and taskID in the print payload with a fresh one."""
    out = json.loads(json.dumps(obj))  # deep copy
    out["requestID"] = new_rid
    if "task" in out:
        out["task"]["taskID"] = new_rid
    return out


def set_preview_flag(payload: dict, enabled: bool) -> dict:
    task = payload.setdefault("task", {})
    task["preview"] = enabled
    return payload


def clear_documents(payload: dict) -> dict:
    task = payload.setdefault("task", {})
    task["preview"] = False
    task["documents"] = []
    for key in ("totalDocumentCount", "documentCount", "totalDocuments"):
        if key in task:
            task[key] = 0
    return payload


def message_has_preview_url(msg: dict) -> bool:
    if msg.get("previewURL"):
        return True
    for response in msg.get("responses", []) or []:
        if response.get("previewURL"):
            return True
        urls = response.get("urls", []) or []
        if any(urls):
            return True
    return False


def msg_matches(expected: dict, actual: dict) -> bool:
    """Check actual message contains all expected keys/values."""
    for k, v in expected.items():
        if k == "has_previewURL":
            if not message_has_preview_url(actual):
                return False
        elif k == "no_previewURL":
            if message_has_preview_url(actual):
                return False
        else:
            if actual.get(k) != v:
                return False
    return True


def summarize(msg: dict) -> str:
    """Short text summary of a message."""
    cmd = msg.get("cmd", "?")
    status = msg.get("status", msg.get("detail", ""))
    rid = msg.get("requestID", "")[:16]
    tid = msg.get("taskId", msg.get("taskID", ""))[:12]
    doc = msg.get("documentId", "")
    has_url = "url" in json.dumps(msg)
    parts = [f"cmd={cmd}"]
    if status:
        parts.append(f"status={status}")
    if rid:
        parts.append(f"rid={rid}")
    if tid:
        parts.append(f"tid={tid}")
    if doc:
        parts.append(f"doc={doc}")
    if has_url:
        parts.append("+previewURL")
    return " ".join(parts)


# ---------------------------------------------------------------------------
# main async
# ---------------------------------------------------------------------------
async def run_replay(
    setconfig_payload: dict,
    print_payload: dict,
    expected_flow: list[dict],
    case_name: str,
    case_label: str,
    url: str = WS_URL,
    timeout: float = TIMEOUT,
) -> int:
    print(f"[REPLAY] Connecting to {url} ...")
    host, port = parse_ws_url(url)
    try:
        messages = await replay_sync_ws(
            host=host,
            port=port,
            setconfig_payload=setconfig_payload,
            print_payload=print_payload,
            timeout=timeout,
        )

    except (ConnectionRefusedError, OSError) as e:
        print(f"[FAIL] Connection error: {e}")
        print("       Is the Cainiao service running on port 13528?")
        return 1
    except Exception as e:
        print(f"[FAIL] Unexpected error: {type(e).__name__}: {e}")
        return 1

    # ---- verify ----
    # messages[0] is setPrinterConfig response; messages[1:] is the print flow
    print(f"\n[VERIFY] Got {len(messages)} message(s).")
    print(f"         [0] setPrinterConfig response: cmd={messages[0].get('cmd')} status={messages[0].get('status')}")
    print(f"         [1..{len(messages)-1}] print flow ({len(messages)-1} messages)")
    print(f"         Expected print flow: {[e['cmd'] for e in expected_flow]}")

    # save raw result
    result_file = DEFAULT_RESULT_DIR / f"replay_result_{case_name}_{int(time.time())}.json"
    result = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "url": url,
        "case": case_name,
        "case_label": case_label,
        "message_count": len(messages),
        "spc_response": messages[0],
        "print_flow_count": len(messages) - 1,
        "expected_print_flow_count": len(expected_flow),
        "messages": messages,
        "flow_verified": False,
        "failures": [],
    }
    result_file.parent.mkdir(parents=True, exist_ok=True)

    # 1) Verify setPrinterConfig response
    failures = []
    if messages[0].get("cmd") != "setPrinterConfig" or messages[0].get("status") != "success":
        failures.append(f"setPrinterConfig response: expected success, got {messages[0].get('status')}")

    # 2) Verify print flow count
    print_msgs = messages[1:]
    if len(print_msgs) != len(expected_flow):
        failures.append(
            f"Print flow message count: expected {len(expected_flow)}, got {len(print_msgs)}"
        )
        # still try to match what we have
        min_len = min(len(print_msgs), len(expected_flow))
    else:
        min_len = len(expected_flow)

    # 3) Verify each message in the print flow
    for i in range(min_len):
        exp = expected_flow[i]
        act = print_msgs[i]
        if not msg_matches(exp, act):
            desc = (
                f"print_flow[{i}]: expected {exp.get('cmd')}/{exp.get('status')}"
                f" but got cmd={act.get('cmd')}/status={act.get('status')}"
            )
            failures.append(desc)

    if failures:
        result["failures"] = failures
        result_file.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(f"[FAIL] {len(failures)} assertion(s) failed:")
        for f in failures:
            print(f"       - {f}")
        print(f"[INFO] Saved raw result to {result_file}")
        return 2

    result["flow_verified"] = True
    result_file.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"\n[PASS] Case {case_name} verified! All {len(expected_flow)} messages match expected pattern.")
    print(f"[INFO] Saved raw result to {result_file}")
    return 0


async def replay_sync_ws(
    host: str,
    port: int,
    setconfig_payload: dict,
    print_payload: dict,
    timeout: float,
) -> list[dict]:
    return await asyncio.to_thread(
        replay_sync_ws_blocking,
        host,
        port,
        setconfig_payload,
        print_payload,
        timeout,
    )


def replay_sync_ws_blocking(
    host: str,
    port: int,
    setconfig_payload: dict,
    print_payload: dict,
    timeout: float,
) -> list[dict]:
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(timeout)
    try:
        perform_ws_handshake(sock, host, port)
        print("[REPLAY] Connected.")
        messages: list[dict] = []

        spc_req = setconfig_payload
        spc_str = json.dumps(spc_req, ensure_ascii=False)
        print(f"[SEND] setPrinterConfig (requestID={spc_req.get('requestID')})")
        send_ws_text(sock, spc_str)

        msg = recv_ws_json(sock, timeout)
        messages.append(msg)
        print(f"  [RECV] {summarize(msg)}")

        new_rid = make_request_id()
        print_req = replace_request_ids(print_payload, new_rid)
        task = print_req.setdefault("task", {})
        print_str = json.dumps(print_req, ensure_ascii=False)
        doc_ids = [d.get("documentID", "?") for d in task.get("documents", [])]
        print(f"[SEND] print (requestID={new_rid}, docs={doc_ids}, preview={task.get('preview')})")
        print(f"       payload_size={len(print_str)} bytes")
        send_ws_text(sock, print_str)

        last_msg_time = time.monotonic()
        while time.monotonic() - last_msg_time < timeout:
            try:
                msg = recv_ws_json(sock, 0.5)
            except TimeoutError:
                continue
            messages.append(msg)
            last_msg_time = time.monotonic()
            print(f"  [RECV] ({len(messages)}) {summarize(msg)}")

        return messages
    finally:
        try:
            send_ws_close(sock)
        except Exception:
            pass
        sock.close()


def parse_ws_url(url: str) -> tuple[str, int]:
    if not url.startswith("ws://"):
        raise ValueError("only ws:// URLs are supported in this replay script")
    remainder = url[5:]
    if "/" in remainder:
        remainder = remainder.split("/", 1)[0]
    if ":" in remainder:
        host, port_text = remainder.rsplit(":", 1)
        return host, int(port_text)
    return remainder, 80


def perform_ws_handshake(sock: socket.socket, host: str, port: int) -> None:
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
    response = recv_http_headers(sock)
    if b"101 Switching Protocols" not in response:
        raise ConnectionError(f"websocket handshake failed: {response!r}")


def recv_http_headers(sock: socket.socket) -> bytes:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("socket closed during websocket handshake")
        data += chunk
    return data


def send_ws_text(sock: socket.socket, text: str) -> None:
    payload = text.encode("utf-8")
    header = bytearray()
    header.append(0x81)
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


def recv_ws_json(sock: socket.socket, timeout: float) -> dict:
    sock.settimeout(timeout)
    first_two = recv_exact(sock, 2)
    first = first_two[0]
    second = first_two[1]
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = int.from_bytes(recv_exact(sock, 2), "big")
    elif length == 127:
        length = int.from_bytes(recv_exact(sock, 8), "big")
    mask = recv_exact(sock, 4) if masked else b""
    payload = recv_exact(sock, length)
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    if opcode == 0x8:
        raise ConnectionError("websocket closed")
    if opcode != 0x1:
        raise ConnectionError(f"unexpected websocket opcode: {opcode}")
    return json.loads(payload.decode("utf-8"))


def send_ws_close(sock: socket.socket) -> None:
    sock.sendall(b"\x88\x00")


def recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("socket closed unexpectedly")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


# ---------------------------------------------------------------------------
# CLI entry
# ---------------------------------------------------------------------------
def main():
    import argparse

    parser = argparse.ArgumentParser(description="Replay Cainiao 13528 protocol flows")
    parser.add_argument("--url", default=WS_URL, help=f"WebSocket URL (default: {WS_URL})")
    parser.add_argument("--setconfig", type=Path, default=DEFAULT_SETCONFIG, help="setPrinterConfig payload JSON")
    parser.add_argument("--print", type=Path, dest="print_path", default=DEFAULT_PRINT, help="print payload JSON")
    parser.add_argument("--case", choices=sorted(SCENARIOS.keys()), default="preview", help="flow to verify")
    parser.add_argument("--timeout", type=float, default=TIMEOUT, help="response collection timeout (seconds)")
    args = parser.parse_args()

    scenario = SCENARIOS[args.case]
    setconfig = load_payload(args.setconfig, "setPrinterConfig")
    print_payload = load_payload(args.print_path, "print")
    if "task" not in print_payload or "documents" not in print_payload.get("task", {}):
        print(f"[FAIL] print payload missing task.documents")
        sys.exit(1)

    print_payload = scenario["configure"](print_payload)

    print(f"[REPLAY] case: {args.case} ({scenario['label']})")
    print(f"[REPLAY] setPrinterConfig: {args.setconfig}")
    print(f"[REPLAY] print: {args.print_path}")
    print(f"[REPLAY] docs: {[d['documentID'] for d in print_payload['task']['documents']]}")

    exit_code = asyncio.run(
        run_replay(
            setconfig,
            print_payload,
            scenario["expected_flow"],
            args.case,
            scenario["label"],
            args.url,
            args.timeout,
        )
    )
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
