#!/usr/bin/env python3
"""Installs every server of the MCP catalog into the running, sandboxed app from
zero and checks that each one connects.

Why from zero: files the sandboxed app creates are quarantined and the kernel
will not exec a quarantined script, so `npx` / `uvx` servers only ever started
when a cache warmed outside the app already held them. The app now installs
each package into its own folder and runs it through node / python; this
removes that folder first, so the run proves the first start works.

For every entry it installs through the `mcpInstall` action (the settings
pane's 安装), waits for the connection, compares the tool count with the one
recorded when the pinned version was verified, and removes the server again,
then checks that no process of it is left. Downloads packages: network needed.

    python3 -I tools/ompshot/scenario_mcp_catalog.py [--only id,id]
"""

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("scenario_codex", os.path.join(HERE, "scenario_codex.py"))
codex = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(codex)

PACKAGE_ROOT = os.path.expanduser(
    "~/Library/Containers/com.ace.ompchat/Data/Library/Application Support/OMPChat/mcp-packages"
)

# id -> (tool count recorded when the pinned version was checked, install answers)
CATALOG = {
    "sequential-thinking": (1, {}),
    "memory": (9, {"folder": ["{tmp}"]}),
    "filesystem": (14, {"directories": ["{tmp}"]}),
    "fetch": (1, {}),
    "git": (12, {}),
    "playwright": (25, {}),
    "chrome-devtools": (32, {}),
}


def leftovers():
    """Processes started from the app's package folder or by uvx for a catalog server."""
    found = []
    for pattern in (PACKAGE_ROOT, "mcp_server_fetch", "mcp_server_git"):
        result = subprocess.run(["pgrep", "-fl", pattern], capture_output=True, text=True)
        found += [line for line in result.stdout.splitlines() if "pgrep" not in line and "scenario_mcp" not in line]
    return found


def wait_status(relay, server_id, timeout):
    deadline = time.time() + timeout
    server = {}
    while time.time() < deadline:
        server = next((s for s in relay.state()["mcpServers"] if s["id"] == server_id), {})
        if server and server["status"] not in ("connecting", "disabled"):
            return server
        time.sleep(2)
    return server


def run(relay, only, check):
    baseline = {s["id"] for s in relay.state()["mcpServers"]}
    # /private/tmp, not $TMPDIR: the sandboxed app cannot see /var/folders.
    tmp = tempfile.mkdtemp(prefix="omp-mcp-cat-", dir="/private/tmp")
    shutil.rmtree(PACKAGE_ROOT, ignore_errors=True)
    installed = []
    try:
        for entry_id, (expected, answers) in CATALOG.items():
            if only and entry_id not in only:
                continue
            print(f"{entry_id}")
            values = {key: [item.replace("{tmp}", tmp) for item in items] for key, items in answers.items()}
            started = time.time()
            before = {s["id"] for s in relay.state()["mcpServers"]}
            reply = relay.act("mcpInstall", entryID=entry_id, values=values)
            check(f"{entry_id}: 安装目录条目", reply.get("ok"), reply.get("error", ""))
            added = [s["id"] for s in relay.state()["mcpServers"] if s["id"] not in before]
            if not added:
                continue
            server_id = added[0]
            installed.append(server_id)
            server = wait_status(relay, server_id, 420)
            elapsed = int(time.time() - started)
            detail = (server.get("detail") or "").replace("\n", " | ")[:300]
            check(f"{entry_id}: 沙盒里从零安装并连上（{elapsed} 秒）", server.get("status") == "ready",
                  f"{server.get('status')} {detail}")
            if server.get("status") == "ready":
                check(f"{entry_id}: 工具数 {expected}", server.get("toolCount") == expected,
                      f"实际 {server.get('toolCount')}")
    finally:
        for server_id in installed:
            relay.act("mcpRemove", serverID=server_id)
        shutil.rmtree(tmp, ignore_errors=True)
    time.sleep(4)
    after = {s["id"] for s in relay.state()["mcpServers"]}
    check("目录服务器都已移除", after == baseline)
    left = leftovers()
    check("移除后没有残留的服务器进程", not left, "; ".join(left)[:300])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", help="只测这些目录条目，逗号分隔")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token")
    args = parser.parse_args()
    relay = codex.Relay(args.host, args.port, codex.ompshot.resolve_token(args.token))
    check = codex.Checks()
    only = set(args.only.split(",")) if args.only else None
    try:
        run(relay, only, check)
    except (RuntimeError, urllib.error.URLError, KeyError, StopIteration, IndexError) as error:
        check("场景跑完", False, f"{type(error).__name__}: {error}")
    print(f"\n{check.passed} 通过，{len(check.failed)} 失败")
    sys.exit(0 if not check.failed else 1)


if __name__ == "__main__":
    main()
