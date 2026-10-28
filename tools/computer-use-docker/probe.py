#!/usr/bin/env python3
"""Probes the computer-use Docker container over an SSH tunnel.

    python3 tools/computer-use-docker/probe.py [host] [port]

Prints the tool list, the running apps and the focused app's accessibility
tree. Exit 0 when the server answers everything.
"""

import json
import socket
import sys


def rpc(sock, rid, method, params=None):
    req = {"jsonrpc": "2.0", "id": rid, "method": method}
    if params is not None:
        req["params"] = params
    sock.sendall(json.dumps(req, separators=(",", ":")).encode() + b"\n")
    buf = b""
    marker = f'"id":{rid}'.encode()
    while marker not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            break
        buf += chunk
    for line in buf.split(b"\n"):
        if marker in line:
            return json.loads(line)
    return None


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8766
    sock = socket.create_connection((host, port), timeout=25)
    hello = rpc(sock, 1, "initialize", {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "ompchat-probe", "version": "1"},
    })
    if not hello:
        sys.exit("initialize 没有回应")
    print("server:", hello["result"]["serverInfo"])
    sock.sendall(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    tools = rpc(sock, 2, "tools/list")
    print("tools:", ", ".join(t["name"] for t in tools["result"]["tools"]))
    apps = rpc(sock, 3, "tools/call", {"name": "list_apps", "arguments": {}})
    print("apps:", apps["result"]["content"][0]["text"].strip()[:200])
    state = rpc(sock, 4, "tools/call", {
        "name": "get_app_state", "arguments": {"app": "gtk3-demo-application"},
    })
    text = state["result"]["content"][0]["text"]
    print("state:", text[:300].replace("\n", " | "))
    sock.close()


if __name__ == "__main__":
    main()
