#!/usr/bin/env python3
"""Black-box scenario for the Codex-aligned desktop features, run in the background.

Drives the installed OMPChat only through its token-gated relay routes
(/debug/action, /debug/state, /debug/windows, /debug/snapshot) — the app is
never activated and no screen pixels are read. Every feature is checked by its
observable state; window snapshots are saved for visual review.

It touches as little real data as possible: it works in a conversation it
creates and deletes, in a temporary git repository it removes, and it puts back
the selection, sidebar settings and every unread flag it found.

    python3 -I tools/ompshot/scenario_codex.py
    python3 -I tools/ompshot/scenario_codex.py --shots .artifacts/shots/scenario

Exit status is 0 only when every check passed. Needs 设置 → 远程控制 enabled.
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
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("ompshot", os.path.join(HERE, "ompshot.py"))
ompshot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ompshot)

GIT = next((p for p in ("/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git")
            if os.access(p, os.X_OK)), None)


class Relay:
    def __init__(self, host, port, token):
        self.base = f"http://{host}:{port}"
        self.token = token

    def call(self, path, body=None):
        """Returns (status, bytes, content type); HTTP errors are values here."""
        headers = {"X-OMP-Token": self.token}
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.status, response.read(), response.headers.get("Content-Type", "")
        except urllib.error.HTTPError as error:
            return error.code, error.read(), error.headers.get("Content-Type", "")

    def state(self):
        status, body, _ = self.call("/debug/state")
        if status != 200:
            raise RuntimeError(f"/debug/state answered {status}")
        return json.loads(body)

    def act(self, action, **fields):
        status, body, _ = self.call("/debug/action", {"action": action, **fields})
        if status != 200:
            raise RuntimeError(f"{action} answered HTTP {status}")
        return json.loads(body)

    def windows(self):
        status, body, _ = self.call("/debug/windows")
        return json.loads(body).get("windows", []) if status == 200 else []

    def snap(self, path, window=None):
        query = f"?window={window}" if window is not None else ""
        status, body, content_type = self.call("/debug/snapshot" + query)
        if status != 200 or not content_type.startswith("image/png"):
            return None
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(body)
        return path


class Checks:
    def __init__(self):
        self.passed = 0
        self.failed = []

    def __call__(self, name, condition, detail=""):
        if condition:
            self.passed += 1
            print(f"  PASS  {name}")
        else:
            self.failed.append(name)
            print(f"  FAIL  {name}" + (f"  ({detail})" if detail else ""))
        return condition


def git(*args, cwd):
    # quotePath=false: git escapes non-ASCII paths otherwise, and worktrees
    # named after a Chinese title would never match.
    return subprocess.run([GIT, "-c", "core.quotePath=false", *args], cwd=cwd,
                          capture_output=True, text=True, timeout=60)


def settle():
    # Actions return after the model changed; give SwiftUI a frame or two to
    # render before a snapshot and the store a moment to persist.
    time.sleep(0.6)


def run(relay, shots, check):
    baseline = relay.state()
    created = []
    root = f"/private/tmp/omp-scenario-{os.getpid()}"
    repo = os.path.join(root, "repo")
    try:
        print("设置窗口")
        check("openSettings 成功", relay.act("openSettings").get("ok"))
        check("设置窗口可见", relay.state()["settingsOpen"])
        settings = next((w for w in relay.windows() if w["title"] == "OMPChat Settings" and w["visible"]), None)
        if settings:
            relay.snap(os.path.join(shots, "01-settings.png"), settings["number"])
        check("closeSettings 成功", relay.act("closeSettings").get("ok"))
        check("设置窗口已关闭", not relay.state()["settingsOpen"])
        check("再次打开（复用已关闭的窗口）", relay.act("openSettings").get("ok") and relay.state()["settingsOpen"])
        relay.act("closeSettings")

        print("新对话与草稿格式")
        check("newChat 成功", relay.act("newChat").get("ok"))
        scenario_id = relay.state()["selectedID"]
        created.append(scenario_id)
        check("选中了新对话", scenario_id and scenario_id != baseline.get("selectedID"))

        def formatted(text, *styles):
            relay.act("setDraft", text=text)
            for style in styles:
                relay.act("format", style=style)
            return relay.state()["draft"]

        check("标题 2", formatted("标题文字", "heading2") == "## 标题文字")
        check("同级标题再按一次取消", formatted("标题文字", "heading2", "heading2") == "标题文字")
        check("换级替换原有标题", formatted("标题文字", "heading1", "heading3") == "### 标题文字")
        check("段落去掉标题", formatted("## 甲", "paragraph") == "甲")
        check("编号只改最后一段", formatted("第一段\n\n甲\n乙", "numberedList") == "第一段\n\n1. 甲\n2. 乙")
        check("无序列表开关", formatted("甲\n乙", "bulletedList", "bulletedList") == "甲\n乙")
        check("加粗", formatted("重点", "bold") == "**重点**")
        check("链接", formatted("官网", "link") == "[官网](https://)")
        formatted("甲\n乙", "bulletedList")
        settle()
        relay.snap(os.path.join(shots, "02-draft-list.png"))
        relay.act("setDraft", text="")

        print("线程目标")
        goal = "发布前补齐协议文档"
        check("setGoal 成功", relay.act("setGoal", goal=goal).get("ok"))
        check("目标已保存", relay.state()["selected"].get("goal") == goal)
        settle()
        relay.snap(os.path.join(shots, "03-goal-chip.png"))
        relay.act("setGoal", goal="  ")
        check("空白目标等于清除", relay.state()["selected"].get("goal") is None)

        print("继续于 / 工作目录 / 侧面板")
        os.makedirs(repo)
        with open(os.path.join(repo, "a.txt"), "w", encoding="utf-8") as handle:
            handle.write("scenario\n")
        for args in (("init", "-q"), ("config", "user.email", "scenario@example.com"),
                     ("config", "user.name", "scenario"), ("add", "-A"), ("commit", "-qm", "init")):
            git(*args, cwd=repo)
        check("继续于选择文件夹", relay.act("continueIn", mode="folder", path=repo).get("ok"))
        check("对话绑定了仓库", relay.state()["selected"].get("workingDirectory") == repo)
        check("不存在的文件夹被拒绝",
              not relay.act("continueIn", mode="folder", path=os.path.join(root, "missing")).get("ok"))
        relay.act("sidePanel", open=True, tab="files")
        settle()
        relay.snap(os.path.join(shots, "04-bound-files.png"))
        with open(os.path.join(repo, "a.txt"), "a", encoding="utf-8") as handle:
            handle.write("changed\n")
        # A Chinese name with a space: plain porcelain would show it escaped.
        spaced = os.path.join(repo, "说明 文档.md")
        with open(spaced, "w", encoding="utf-8") as handle:
            handle.write("新文件\n")
        relay.act("sidePanel", open=True, tab="changes")
        settle()
        relay.snap(os.path.join(shots, "05-bound-changes.png"))
        git("checkout", "--", "a.txt", cwd=repo)
        os.remove(spaced)

        reply = relay.act("continueIn", mode="worktree")
        check("继续于新建 Worktree", reply.get("ok"), reply.get("error", ""))
        state = relay.state()
        moved = state["selected"].get("workingDirectory") or ""
        check("仍是同一个对话", state["selectedID"] == scenario_id)
        check("改绑到新的 checkout", moved and moved != repo and os.path.exists(os.path.join(moved, "a.txt")), moved)
        check("git 认得这个 worktree", moved and moved in git("worktree", "list", cwd=repo).stdout)

        print("分叉对话")
        reply = relay.act("fork", mode="sameWorktree")
        copy = relay.state()
        created.append(copy["selectedID"])
        check("同一工作目录分叉", reply.get("ok") and copy["selectedID"] != scenario_id
              and copy["selected"].get("workingDirectory") == moved)
        relay.act("select", conversationID=scenario_id)
        reply = relay.act("fork", mode="worktree")
        copy = relay.state()
        created.append(copy["selectedID"])
        forked = copy["selected"].get("workingDirectory") or ""
        check("新建 Worktree 分叉", reply.get("ok") and forked not in ("", moved)
              and os.path.exists(os.path.join(forked, "a.txt")), reply.get("error", forked))
        relay.act("select", conversationID=scenario_id)
        relay.act("fork", mode="local")
        copy = relay.state()
        created.append(copy["selectedID"])
        check("本地副本不绑定目录", copy["selected"].get("workingDirectory") is None
              and copy["selected"]["title"].endswith("(副本)"))

        print("整理侧栏")
        check("按连接 + 只看工作", relay.act("sidebar", grouping="connection", filter="work").get("ok"))
        state = relay.state()
        check("设置已生效", state["sidebarGrouping"] == "connection" and state["sidebarFilter"] == "work")
        relay.act("select", conversationID=scenario_id)
        settle()
        relay.snap(os.path.join(shots, "06-sidebar-connection-work.png"))
        relay.act("sidebar", filter="chat")
        settle()
        relay.snap(os.path.join(shots, "07-sidebar-connection-chat.png"))
        relay.act("sidebar", grouping=baseline["sidebarGrouping"], filter=baseline["sidebarFilter"])
        state = relay.state()
        check("侧栏设置已还原", state["sidebarGrouping"] == baseline["sidebarGrouping"]
              and state["sidebarFilter"] == baseline["sidebarFilter"])

        print("应用链接")
        relay.act("select", conversationID=created[-1])
        check("openLink 选中目标对话",
              relay.act("openLink", url=f"ompchat://thread/{scenario_id}").get("ok")
              and relay.state()["selectedID"] == scenario_id)
        check("不存在的对话报错", not relay.act("openLink", url=f"ompchat://thread/{uuid.uuid4()}").get("ok"))
        check("别的链接报错", not relay.act("openLink", url="https://example.com").get("ok"))

        print("未读与待处理")
        relay.act("setUnread", conversationID=scenario_id, unread=True)
        state = relay.state()
        check("标为未读进入待处理", scenario_id in state["unreadIDs"] and scenario_id in state["priorityIDs"])
        relay.act("markAllRead")
        check("全部标为已读", relay.state()["unreadIDs"] == [])
        for unread_id in baseline["unreadIDs"]:
            relay.act("setUnread", conversationID=unread_id, unread=True)
        check("原有未读已还原", relay.state()["unreadIDs"] == baseline["unreadIDs"])

        print("继续于本地")
        relay.act("select", conversationID=scenario_id)
        relay.act("continueIn", mode="local")
        check("解除绑定", relay.state()["selected"].get("workingDirectory") is None)

        print("错误输入")
        status, _, _ = relay.call("/debug/action", {"action": "format", "style": "heading4"})
        check("未知格式返回 400", status == 400)
        status, _, _ = relay.call("/debug/action", {"action": "sidebar"})
        check("空的整理侧栏返回 400", status == 400)
    finally:
        for conversation_id in created:
            relay.act("delete", conversationID=conversation_id)
        if os.path.isdir(repo):
            for line in git("worktree", "list", "--porcelain", cwd=repo).stdout.splitlines():
                path = line.removeprefix("worktree ")
                if line.startswith("worktree ") and path != repo:
                    git("worktree", "remove", "--force", path, cwd=repo)
        shutil.rmtree(root, ignore_errors=True)
        relay.act("sidePanel", open=baseline["sidePanelOpen"])
        if baseline.get("selectedID"):
            relay.act("select", conversationID=baseline["selectedID"])
        relay.act("closeSettings")

    after = relay.state()
    check("场景对话都已删除", not set(created) & set(after.get("priorityIDs", [])) and
          after["conversationCount"] == baseline["conversationCount"],
          f"{baseline['conversationCount']} → {after['conversationCount']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token")
    parser.add_argument("--shots", default=".artifacts/shots/scenario")
    args = parser.parse_args()
    if GIT is None:
        sys.exit("没有可用的 git")
    relay = Relay(args.host, args.port, ompshot.resolve_token(args.token))
    check = Checks()
    try:
        run(relay, args.shots, check)
    except (RuntimeError, urllib.error.URLError, KeyError) as error:
        check("场景跑完", False, str(error))
    print(f"\n{check.passed} 通过，{len(check.failed)} 失败；截图在 {args.shots}")
    sys.exit(0 if not check.failed else 1)


if __name__ == "__main__":
    main()
