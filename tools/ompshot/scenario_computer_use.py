#!/usr/bin/env python3
"""Handshake-only check of the computer-use MCP server inside the sandboxed app.

Answers one question that cannot be settled by reading code: can a child
process started by the sandboxed OMPChat even run the vetted server
(opensymph/open-computer-use, pinned in ComputerUseCatalog)? It

  1. adds the primary server through the `computerUseAdd` action (the config
     设置 → 电脑控制 stores, enabled),
  2. waits for the app's MCP client to finish `initialize` + `tools/list`,
  3. records the status and tool names and snapshots the 电脑控制 pane,
  4. removes the server again, whatever happened.

It never calls one of the server's tools, never sends a message, and grants no
macOS permission, so nothing on the desktop is seen or touched. The first run
downloads the pinned package, so it needs network access. Because it starts a
program that can control the desktop once permissions exist, it only runs with
--allow-handshake.

Exit status: 0 the server connected; 1 something failed; 2 the sandbox refused
to run the package's native app (`spawn EPERM`). Measured on 2026-10-27: a
sandboxed process cannot exec any executable a sandboxed process created, not
even a copy of /bin/echo, so a package extracted by the app can never start its
native binary. That is a limit of the sandbox, not a failure of the code, and
it is reported as its own result instead of a pass or a failure.

    python3 -I tools/ompshot/scenario_computer_use.py --allow-handshake
"""

import argparse
import importlib.util
import json
import os
import sys
import time
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("scenario_codex", os.path.join(HERE, "scenario_codex.py"))
codex = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(codex)


def run(relay, shots, check, blocked):
    baseline = relay.state()
    before = {s["id"] for s in baseline["mcpServers"]}
    added = []
    try:
        reply = relay.act("computerUseAdd")
        check("添加固定版本的电脑控制服务器", reply.get("ok"), reply.get("error", ""))
        deadline = time.time() + 300  # first run downloads the package
        server = {}
        while time.time() < deadline:
            current = [s for s in relay.state()["mcpServers"] if s["id"] not in before]
            added = [s["id"] for s in current]
            server = current[0] if current else {}
            if server and server["status"] not in ("connecting", "disabled"):
                break
            time.sleep(2)
        status = server.get("status")
        print(f"  状态：{status}，工具数：{server.get('toolCount')}")
        for tool in server.get("tools", []):
            print(f"    - {tool}")
        if server.get("detail"):
            print("  详情：" + server["detail"].replace("\n", "\n        "))
        text = server.get("detail") or ""
        if status != "ready" and ("EPERM" in text or "Operation not permitted" in text):
            blocked.append(text.replace("\n", " | ")[:300])
        else:
            check("沙盒里的子进程完成了握手并列出工具", status == "ready" and (server.get("toolCount") or 0) > 0,
                  json.dumps(server, ensure_ascii=False)[:500])
        state = relay.state()
        check("没有产生待批准的操作", not state["pendingApprovals"] and not state["runningToolCallIDs"])
        check("没有新增对话", state["conversationCount"] == baseline["conversationCount"])
        relay.act("openSettings", section="computerUse")
        codex.settle()
        settings = next((w for w in relay.windows() if w["title"] == "OMPChat Settings" and w["visible"]), None)
        if settings:
            relay.snap(os.path.join(shots, "01-computer-use-pane.png"), settings["number"])
        relay.act("closeSettings")
    finally:
        for server_id in added:
            relay.act("mcpRemove", serverID=server_id)
    after = relay.state()
    check("服务器已移除", {s["id"] for s in after["mcpServers"]} == before)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--allow-handshake", action="store_true",
                        help="确认可以在本机启动这个电脑控制服务器做一次握手（不调用任何工具）")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token")
    parser.add_argument("--shots", default=".artifacts/shots/computer-use")
    args = parser.parse_args()
    if not args.allow_handshake:
        sys.exit("没有传 --allow-handshake：这会在本机启动一个能控制桌面的第三方服务器（只握手，不调用工具）。")
    relay = codex.Relay(args.host, args.port, codex.ompshot.resolve_token(args.token))
    check = codex.Checks()
    blocked = []
    try:
        run(relay, args.shots, check, blocked)
    except (RuntimeError, urllib.error.URLError, KeyError, StopIteration, IndexError) as error:
        check("场景跑完", False, f"{type(error).__name__}: {error}")
    print(f"\n{check.passed} 通过，{len(check.failed)} 失败；截图在 {args.shots}")
    if check.failed:
        sys.exit(1)
    if blocked:
        print("阻塞：沙盒不允许执行包里的原生程序（spawn EPERM）：" + blocked[0])
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
