#!/usr/bin/env python3
"""Hub RPC correlation and command forwarding test.

Starts relay_hub on a free port, opens a fake host SSE stream, and checks:

- a client RPC is correlated back by request id
- an unknown op is rejected with 400 and never reaches the host
- no host online is 409
- a host that never answers is 504 (timeout shortened via RPC_TIMEOUT_SECONDS)
- a host that disconnects mid-wait is 409
- an `approve` command reaches the host with every field; one with a missing
  id, an unknown decision or `allowAlways` is 400 and never reaches it
- `sendQueuedNow` / `removeQueued` reach the host; one without a
  conversation or queued id is 400 and never reaches it

Run: python3 tools/relay-hub/test_rpc.py
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
HUB = os.path.join(HERE, "relay_hub.py")
ROOM = "HSTABC"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def http(port: int, method: str, path: str, body: dict | None = None, timeout: float = 10) -> tuple[int, dict]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if data else {},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read()
        payload = json.loads(raw) if raw else {}
        return error.code, payload


class HostStream:
    """Minimal SSE client for GET /v1/host/stream."""

    def __init__(self, port: int) -> None:
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.sock.sendall(
            f"GET /v1/host/stream?room={ROOM} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".encode()
        )
        self.buffer = b""
        self._read_until(b"\r\n\r\n")

    def _read_until(self, marker: bytes, timeout: float = 5) -> bytes:
        deadline = time.time() + timeout
        while marker not in self.buffer:
            if time.time() > deadline:
                raise TimeoutError("host stream stalled")
            self.sock.settimeout(max(0.1, deadline - time.time()))
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("host stream closed")
            self.buffer += chunk
        head, _, self.buffer = self.buffer.partition(marker)
        return head

    def next_event(self, timeout: float = 5) -> tuple[str, str]:
        while True:
            block = self._read_until(b"\n\n", timeout=timeout).decode()
            name, data = "message", ""
            for line in block.split("\n"):
                if line.startswith(":"):
                    continue
                if line.startswith("event:"):
                    name = line[6:].strip()
                elif line.startswith("data:"):
                    data += line[5:].lstrip()
            if name == "message" and not data:
                continue
            return name, data

    def close(self) -> None:
        self.sock.close()


def main() -> int:
    port = free_port()
    env = os.environ.copy()
    # Short timeout so the 504 case finishes in the test, not after 130s.
    # The hub reads the constant; patch it for this process only by wrapping.
    hub = subprocess.Popen(
        [sys.executable, "-c", patched_launcher(port)],
        cwd=HERE,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    try:
        wait_until_up(port)
        run(port)
    finally:
        hub.terminate()
        try:
            hub.wait(timeout=5)
        except subprocess.TimeoutExpired:
            hub.kill()
    print("hub rpc: all assertions passed")
    return 0


def patched_launcher(port: int) -> str:
    # Import once. runpy.run_module would load a second copy and the
    # RPC_TIMEOUT_SECONDS patch on the first copy would never be read.
    return (
        "import sys, asyncio\n"
        "import relay_hub\n"
        "relay_hub.RPC_TIMEOUT_SECONDS = 2.0\n"
        f"sys.argv = ['relay_hub.py', '--host', '127.0.0.1', '--port', '{port}']\n"
        "asyncio.run(relay_hub.main())\n"
    )


def wait_until_up(port: int) -> None:
    deadline = time.time() + 5
    while time.time() < deadline:
        try:
            status, _ = http(port, "GET", "/v1/health")
            if status == 200:
                return
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            time.sleep(0.05)
    raise SystemExit("hub did not start")


def run(port: int) -> None:
    # 409: no host yet.
    status, body = http(port, "POST", f"/v1/client/rpc?room={ROOM}", {"id": "none", "op": "info"})
    assert status == 409, (status, body)
    print(f"no-host 409: {body}")

    host = HostStream(port)
    name, _ = host.next_event()
    assert name == "hello", name

    # Unknown op never reaches the host.
    status, body = http(port, "POST", f"/v1/client/rpc?room={ROOM}", {"id": "bad", "op": "rm-rf"})
    assert status == 400, (status, body)
    print(f"bad-op 400: {body}")

    # Correlation: client posts, host sees event: rpc, host answers, client gets it.
    import threading

    box: dict[str, tuple[int, dict]] = {}

    def client() -> None:
        box["result"] = http(
            port, "POST", f"/v1/client/rpc?room={ROOM}",
            {"id": "req-1", "op": "exec", "command": "pwd"},
            timeout=10,
        )

    thread = threading.Thread(target=client)
    thread.start()
    name, data = host.next_event()
    assert name == "rpc", name
    request = json.loads(data)
    assert request["id"] == "req-1", request
    assert request["command"] == "pwd", request
    status, body = http(
        port, "POST", f"/v1/host/rpc-result?room={ROOM}",
        {"id": "req-1", "ok": True, "stdout": "/Users/me", "exitCode": 0},
    )
    assert status == 200, (status, body)
    thread.join(timeout=5)
    status, body = box["result"]
    assert status == 200, (status, body)
    assert body["id"] == "req-1" and body["stdout"] == "/Users/me" and body["ok"] is True, body
    print(f"correlated 200: {body}")

    # Two in flight stay correlated to their own ids.
    def client2(key: str, request_id: str) -> None:
        box[key] = http(
            port, "POST", f"/v1/client/rpc?room={ROOM}",
            {"id": request_id, "op": "info"},
            timeout=10,
        )

    threads = [
        threading.Thread(target=client2, args=("a", "req-a")),
        threading.Thread(target=client2, args=("b", "req-b")),
    ]
    for item in threads:
        item.start()
    seen = {}
    for _ in range(2):
        name, data = host.next_event()
        assert name == "rpc"
        seen[json.loads(data)["id"]] = True
    assert seen == {"req-a": True, "req-b": True}
    # Answer out of order.
    http(port, "POST", f"/v1/host/rpc-result?room={ROOM}", {"id": "req-b", "ok": True, "text": "B"})
    http(port, "POST", f"/v1/host/rpc-result?room={ROOM}", {"id": "req-a", "ok": True, "text": "A"})
    for item in threads:
        item.join(timeout=5)
    assert box["a"][1]["text"] == "A", box["a"]
    assert box["b"][1]["text"] == "B", box["b"]
    # exec.cancel rides the same pipe and correlation as any op.
    def cancel_client() -> None:
        box["cancel"] = http(
            port, "POST", f"/v1/client/rpc?room={ROOM}",
            {"id": "cancel-op", "op": "exec.cancel", "requestID": "exec-42"},
            timeout=10,
        )

    thread = threading.Thread(target=cancel_client)
    thread.start()
    name, data = host.next_event()
    assert name == "rpc", name
    cancel_request = json.loads(data)
    assert cancel_request["id"] == "cancel-op", cancel_request
    assert cancel_request["requestID"] == "exec-42", cancel_request
    status, body = http(
        port, "POST", f"/v1/host/rpc-result?room={ROOM}",
        {"id": "cancel-op", "ok": True, "text": "cancelling"},
    )
    assert status == 200, (status, body)
    thread.join(timeout=5)
    status, body = box["cancel"]
    assert status == 200, (status, body)
    assert body["text"] == "cancelling", body
    print(f"cancel round trip: {body}")

    # A cancel is still accepted when the room sits at the pending cap:
    # blocking it would deadlock the very command it is meant to stop.
    stuck: list[threading.Thread] = []
    for index in range(32):
        item = threading.Thread(
            target=client2, args=(f"capped-{index}", f"cap-{index}")
        )
        item.start()
        stuck.append(item)
    for _ in range(32):
        name, data = host.next_event()
        assert name == "rpc", name
    status, body = http(
        port, "POST", f"/v1/client/rpc?room={ROOM}",
        {"id": "capped", "op": "info"}, timeout=10,
    )
    assert status == 429, (status, body)
    print(f"cap 429: {body}")
    def capped_cancel() -> None:
        box["freecancel"] = http(
            port, "POST", f"/v1/client/rpc?room={ROOM}",
            {"id": "freecancel", "op": "exec.cancel", "requestID": "cap-0"}, timeout=10,
        )

    thread = threading.Thread(target=capped_cancel)
    thread.start()
    name, data = host.next_event()
    assert json.loads(data)["id"] == "freecancel", data
    status, body = http(
        port, "POST", f"/v1/host/rpc-result?room={ROOM}",
        {"id": "freecancel", "ok": True, "text": "cancelling"},
    )
    assert status == 200, (status, body)
    thread.join(timeout=5)
    status, body = box["freecancel"]
    assert status == 200, (status, body)
    print(f"cancel at cap 200: {body}")

    # exec.poll is a known op and, like exec.cancel, is forwarded even when
    # the room sits at the pending cap.
    def capped_poll() -> None:
        box["freepoll"] = http(
            port, "POST", f"/v1/client/rpc?room={ROOM}",
            {"id": "freepoll", "op": "exec.poll", "requestID": "cap-0", "offset": 128},
            timeout=10,
        )

    thread = threading.Thread(target=capped_poll)
    thread.start()
    name, data = host.next_event()
    poll_request = json.loads(data)
    assert poll_request["id"] == "freepoll", data
    assert poll_request["op"] == "exec.poll", poll_request
    assert poll_request["offset"] == 128, poll_request
    status, body = http(
        port, "POST", f"/v1/host/rpc-result?room={ROOM}",
        {"id": "freepoll", "ok": True, "text": "more", "nextOffset": 132, "done": False},
    )
    assert status == 200, (status, body)
    thread.join(timeout=5)
    status, body = box["freepoll"]
    assert status == 200, (status, body)
    assert body["text"] == "more" and body["nextOffset"] == 132 and body["done"] is False, body
    print(f"poll at cap 200: {body}")
    # Drain the capped calls so later cases start clean.
    for index in range(32):
        http(port, "POST", f"/v1/host/rpc-result?room={ROOM}", {"id": f"cap-{index}", "ok": True, "text": "x"})
    for item in stuck:
        item.join(timeout=5)

    # 504: host never answers. Timeout is patched to 2s.
    started = time.time()
    status, body = http(port, "POST", f"/v1/client/rpc?room={ROOM}", {"id": "slow", "op": "info"}, timeout=8)
    elapsed = time.time() - started
    assert status == 504, (status, body)
    assert 1.5 <= elapsed <= 6, elapsed
    print(f"timeout 504 after {elapsed:.2f}s: {body}")
    # The unanswered call is still sitting in the host buffer.
    name, data = host.next_event()
    assert json.loads(data)["id"] == "slow"

    # approve: forwarded verbatim, with or without a requestID.
    allow = {"kind": "approve", "approvalID": "A1", "decision": "allowOnce", "requestID": "r-1"}
    status, body = http(port, "POST", f"/v1/client/command?room={ROOM}", allow)
    assert status == 200, (status, body)
    name, data = host.next_event()
    assert name == "command", name
    assert json.loads(data) == allow, data
    deny = {"kind": "approve", "approvalID": "A1", "decision": "deny"}
    status, body = http(port, "POST", f"/v1/client/command?room={ROOM}", deny)
    assert status == 200, (status, body)
    name, data = host.next_event()
    assert json.loads(data) == deny, data
    print(f"approve forwarded: {allow['decision']}, {deny['decision']}")

    # A phone never grants allowAlways, and a malformed approve is refused here.
    for bad in [
        {"kind": "approve", "approvalID": "A1", "decision": "allowAlways", "requestID": "r-2"},
        {"kind": "approve", "decision": "deny"},
        {"kind": "approve", "approvalID": "", "decision": "deny"},
        {"kind": "approve", "approvalID": "A1"},
        {"kind": "approve", "approvalID": "A1", "decision": ["deny"]},
        {"kind": "approve", "approvalID": "A1", "decision": "deny", "requestID": 7},
    ]:
        status, body = http(port, "POST", f"/v1/client/command?room={ROOM}", bad)
        assert status == 400 and body == {"error": "bad command"}, (bad, status, body)
    # None of them reached the host: the next event is this marker.
    marker = {"kind": "stop", "conversationID": "marker"}
    status, body = http(port, "POST", f"/v1/client/command?room={ROOM}", marker)
    assert status == 200, (status, body)
    name, data = host.next_event()
    assert json.loads(data) == marker, data
    print("bad approve 400, never forwarded")

    # Queued follow-ups: both kinds forwarded verbatim.
    for kind in ("sendQueuedNow", "removeQueued"):
        command = {"kind": kind, "conversationID": "C1", "queuedID": "Q1"}
        status, body = http(port, "POST", f"/v1/client/command?room={ROOM}", command)
        assert status == 200, (kind, status, body)
        name, data = host.next_event()
        assert name == "command" and json.loads(data) == command, (name, data)
    for bad in [
        {"kind": "sendQueuedNow", "conversationID": "C1"},
        {"kind": "sendQueuedNow", "conversationID": "C1", "queuedID": ""},
        {"kind": "removeQueued", "queuedID": "Q1"},
        {"kind": "removeQueued", "conversationID": "C1", "queuedID": 7},
    ]:
        status, body = http(port, "POST", f"/v1/client/command?room={ROOM}", bad)
        assert status == 400 and body == {"error": "bad command"}, (bad, status, body)
    status, body = http(port, "POST", f"/v1/client/command?room={ROOM}", marker)
    assert status == 200, (status, body)
    name, data = host.next_event()
    assert json.loads(data) == marker, data
    print("queue commands forwarded; malformed ones 400, never forwarded")


if __name__ == "__main__":
    sys.exit(main())
