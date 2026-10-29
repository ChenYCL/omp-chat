#!/usr/bin/env python3
"""Stress scenario hunting the once-seen 27 s main-thread stall (wave 6, the
app hidden in the background, main thread stuck in sidebar LazyVStack
placement while /debug/* refused everything).

It drives the installed app in the background the way normal use does and
probes /debug/state after every step; the first missed probe triggers a
`sample` of the app process (kept in .artifacts/stall/). Steps:

1. toggle the side panel open/closed 20× (the sidebar steps aside/returns);
2. drag the sidebar resizer across its range 10× (via the debug width action
   if present, else window resizes);
3. resize the window 1180 ↔ 950 pt 10× (the overflow boundary);
4. cycle ⌘B sidebar visibility 20×;
5. send a message in a scenario conversation so the transcript streams while
   the layout changes (calls the configured model).

Anything that stalls writes the sample next to the log so the report names
the frame. Everything the scenario creates is deleted; the window size,
panel, sidebar and selection are restored.

    python3 -I tools/ompshot/scenario_stall.py [--live]
"""

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("scenario_codex", os.path.join(HERE, "scenario_codex.py"))
codex = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(codex)

SHOTS = ".artifacts/stall"


def app_pid():
    result = subprocess.run(["pgrep", "-f", "/Applications/OMPChat.app/Contents/MacOS/OMPChat"],
                            capture_output=True, text=True)
    return result.stdout.split()[0] if result.stdout.split() else None


def sample(pid, tag):
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, f"stall-{tag}-{int(time.time())}.txt")
    subprocess.run(["sample", pid, "3", "-file", path], capture_output=True)
    if os.path.exists(path):
        # Pull the heaviest main-thread OMPChat frames to the head of the file
        # so the report does not need to walk 30 MB.
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
            head = text[:600_000]
            frames = []
            for line in head.splitlines():
                if "OMPChat.debug.dylib" in line or ".swift:" in line:
                    cleaned = line.strip()
                    if cleaned not in frames:
                        frames.append(cleaned)
            summary = os.path.join(SHOTS, f"stall-{tag}-{int(time.time())}-frames.txt")
            open(summary, "w").write("\n".join(frames[:40]))
            return summary
        except OSError:
            return path
    return None


def run(relay, check, live):
    baseline = relay.state()
    pid = app_pid()
    check("应用在运行", pid is not None, str(pid))
    misses = []

    def probe(tag):
        """One /debug/state within 8 s, or a sampled miss."""
        start = time.time()
        try:
            relay.call("/debug/state")
            elapsed = time.time() - start
            if elapsed > 3:
                print(f"  ({tag}: 慢 {elapsed:.1f}s)")
            return None
        except Exception as error:
            elapsed = time.time() - start
            current = app_pid() or pid
            path = sample(current, tag) if current else None
            misses.append((tag, elapsed, path))
            print(f"  ({tag}: /debug/state {elapsed:.1f}s 无响应，采样在 {path})")
            return error

    root = f"/private/tmp/omp-stall-{os.getpid()}"
    work = os.path.join(root, "work")
    os.makedirs(work)
    conversation_id = None
    original_size = None
    try:
        window = next((w for w in relay.windows() if w["title"] == "OMPChat"), None)
        if window:
            original_size = (window.get("width"), window.get("height"))

        def resize(width, height=820):
            subprocess.run(["osascript", "-e",
                            f'tell application "System Events" to tell process "OMPChat" '
                            f'to set size of window 1 to {{{width}, {height}}}'], capture_output=True)
            time.sleep(0.4)

        def set_panel(open_, tab="files"):
            relay.act("sidePanel", open=open_, tab=tab)
            time.sleep(0.4)

        print("1. 侧面板开关 20 次")
        for i in range(10):
            set_panel(True); probe(f"panel-open-{i}")
            set_panel(False); probe(f"panel-close-{i}")

        print("2. 侧栏宽度拖拽范围 10 次（经 toggleSidebar + 窗口宽度挤压侧栏进出）")
        relay.act("toggleSidebar"); time.sleep(0.3)
        relay.act("toggleSidebar"); time.sleep(0.3)
        for i, width in enumerate([950, 1000, 1050, 1100, 1150, 1180, 950, 1180, 950, 1180]):
            resize(width); probe(f"resize-{i}-{width}")
        resize(original_size[0] if original_size else 1180)

        print("3. ⌘B 侧栏可见性 20 次")
        for i in range(10):
            relay.act("toggleSidebar"); probe(f"cmdB-on-{i}")
            relay.act("toggleSidebar"); probe(f"cmdB-off-{i}")

        print("4. 面板 + 侧栏 + 窗口挤压组合 10 次")
        for i in range(10):
            set_panel(True)
            resize(950); probe(f"combo-narrow-{i}")
            resize(1180)
            set_panel(False); probe(f"combo-wide-{i}")

        if live:
            print("5. 流式回复时改布局 5 次（调用真实模型）")
            relay.act("newChat")
            conversation_id = relay.state()["selectedID"]
            if not conversation_id or relay.state()["selected"]["messageCount"] != 0:
                raise RuntimeError("newChat did not select a fresh conversation")
            relay.act("continueIn", conversationID=conversation_id, mode="folder", path=work)
            relay.act("setAccess", conversationID=conversation_id, access="chat")
            for i in range(5):
                relay.act("send", conversationID=conversation_id,
                          text=f"第 {i} 轮：请用三句话介绍 AVFoundation 的音频管线。")
                probe(f"stream-send-{i}")
                for step in range(10):
                    set_panel(open_=(step % 2 == 0))
                    probe(f"stream-layout-{i}-{step}")
                    if not relay.state()["isStreaming"]:
                        break
                relay.act("stop")
                time.sleep(1)
    finally:
        relay.act("stop")
        if conversation_id:
            relay.act("delete", conversationID=conversation_id)
        shutil.rmtree(root, ignore_errors=True)
        set_panel(baseline["sidePanelOpen"],
                  **({"tab": baseline["sidePanelTab"]} if baseline.get("sidePanelTab") else {}))
        if not baseline.get("sidebarVisible", True):
            relay.act("toggleSidebar")
        if original_size:
            resize(original_size[0], original_size[1] or 820)
        if baseline.get("selectedID"):
            relay.act("select", conversationID=baseline["selectedID"])

    check("压测全程 /debug/state 未失联", not misses,
          json.dumps([(t, f"{e:.1f}s", p) for t, e, p in misses], ensure_ascii=False)[:400])
    after = relay.state()
    check("场景对话已删除", after["conversationCount"] == baseline["conversationCount"],
          f"{baseline['conversationCount']} → {after['conversationCount']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--live", action="store_true", help="也跑要调用模型的部分")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token")
    args = parser.parse_args()
    relay = codex.Relay(args.host, args.port, codex.ompshot.resolve_token(args.token))
    check = codex.Checks()
    try:
        run(relay, check, args.live)
    except (RuntimeError, urllib.error.URLError, KeyError, StopIteration, IndexError, TypeError) as error:
        check("场景跑完", False, f"{type(error).__name__}: {error}")
    print(f"\n{check.passed} 通过，{len(check.failed)} 失败；采样在 {SHOTS}")
    sys.exit(0 if not check.failed else 1)


if __name__ == "__main__":
    main()
