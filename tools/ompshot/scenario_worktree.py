#!/usr/bin/env python3
"""Background black-box scenario for Codex local environments, Worktree mode,
worktree management and 交接, driven through the relay routes only.

Everything happens in a temporary git repository under /private/tmp:
- 本地环境: an environment with a setup script, a cleanup script and one
  action is saved in the official TOML layout and selected;
- Worktree mode: the first message of a chat with 本地 / Worktree set to
  Worktree creates a detached worktree at HEAD, carries the uncommitted and
  untracked changes, copies the ignored `.env` listed in `.worktreeinclude`,
  runs the setup script there with CODEX_SOURCE_TREE_PATH / CODEX_WORKTREE_PATH,
  and the chat moves into the worktree;
- the header action runs in the side-panel terminal inside the worktree;
- 交接到本地 is refused while the local checkout has a conflicting edit, then
  moves the worktree's changes to the local checkout; 交接到 Worktree takes
  them back into the same worktree;
- deletion is refused for a pinned chat, otherwise snapshots, runs the
  cleanup script and removes the checkout; 恢复 brings the work back;
- archiving the chat deletes its worktree;
- 在此 worktree 新建对话 opens a chat in the same checkout.

The reply to the first message calls the configured model (tools off). The
chats, worktrees and repository are removed at the end and the previous
selection, side panel and link setting are put back.

    python3 -I tools/ompshot/scenario_worktree.py
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

SHOTS = ".artifacts/shots/worktree"

ENVIRONMENT = """version = 1
name = "scenario"

[setup]
script = "printf '%s|%s' \\"$CODEX_SOURCE_TREE_PATH\\" \\"$CODEX_WORKTREE_PATH\\" > setup-ran.txt"

[cleanup]
script = "printf cleaned > \\"$CODEX_SOURCE_TREE_PATH/../cleanup-ran.txt\\""

[[actions]]
name = "写标记"
icon = "run"
command = "echo action-ok > action-ran.txt"
"""


def git(*args, cwd):
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def read(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return None


def write(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def real(path):
    return os.path.realpath(path) if path else path


def wait_for(predicate, timeout, step=0.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


def run(relay, check):
    baseline = relay.state()
    root = f"/private/tmp/omp-worktree-{os.getpid()}"
    repo = os.path.join(root, "repo")
    os.makedirs(repo)
    created = []
    trees = set()

    def state():
        return relay.state()

    def selected():
        return relay.state()["selected"]

    def tree(tree_id):
        return next((t for t in relay.state()["managedWorktrees"] if t["id"] == tree_id), None)

    try:
        for args in (("init", "-q", "-b", "main"), ("config", "user.email", "scenario@example.com"),
                     ("config", "user.name", "scenario"), ("config", "commit.gpgsign", "false")):
            git(*args, cwd=repo)
        write(os.path.join(repo, "app.txt"), "v1\n")
        write(os.path.join(repo, ".gitignore"), ".env\nsetup-ran.txt\naction-ran.txt\n")
        write(os.path.join(repo, ".worktreeinclude"), ".env\n")
        git("add", ".", cwd=repo)
        git("commit", "-qm", "init", cwd=repo)
        write(os.path.join(repo, ".env"), "TOKEN=local-only\n")

        print("本地环境：保存并选中")
        reply = relay.act("localEnvironment", op="save", project=repo, fileName="environment.toml", toml=ENVIRONMENT)
        check("保存环境", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
        env_path = os.path.join(repo, ".codex", "environments", "environment.toml")
        saved = read(env_path) or ""
        check("写成官方格式", "version = 1" in saved and 'name = "scenario"' in saved and "[[actions]]" in saved
              and 'icon = "run"' in saved, saved[:400])
        git("add", ".codex", cwd=repo)
        git("commit", "-qm", "environment", cwd=repo)
        head = git("rev-parse", "HEAD", cwd=repo)
        # Work in progress that Worktree mode must carry over.
        write(os.path.join(repo, "app.txt"), "v2\n")
        write(os.path.join(repo, "notes.txt"), "draft\n")

        print("Worktree 模式：第一条消息先建 worktree")
        relay.act("dismissError")
        relay.act("newChat")
        chat = state()["selectedID"]
        if not chat or selected()["messageCount"] != 0:
            raise RuntimeError("newChat did not select a fresh conversation")
        created.append(chat)
        relay.act("continueIn", conversationID=chat, mode="folder", path=repo)
        relay.act("setAccess", conversationID=chat, access="chat")
        current = selected()
        check("对话看到项目的环境", real(current.get("selectedEnvironment")) == real(env_path)
              and current["environments"] and current["environments"][0]["actions"] == ["写标记"],
              json.dumps({k: current.get(k) for k in ("environments", "selectedEnvironment")}, ensure_ascii=False))
        reply = relay.act("worktree", op="setMode", conversationID=chat, on=True)
        check("切到 Worktree", reply.get("ok") and selected()["worktreeMode"], json.dumps(reply, ensure_ascii=False))
        relay.act("setDraft", text="只回复两个字：好的")
        reply = relay.act("sendDraft", conversationID=chat)
        check("第一条消息发出", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
        current = selected()
        tree_id = current.get("managedWorktreeID")
        record = tree(tree_id) if tree_id else None
        check("建了自管 worktree", record is not None, json.dumps(current.get("managedWorktreeID")))
        if not record:
            raise RuntimeError("no managed worktree")
        trees.add(tree_id)
        path = record["path"]
        check("在 HEAD 处、分离 HEAD", record["baseCommit"] == head and record.get("branch") is None
              and git("rev-parse", "HEAD", cwd=path) == head,
              json.dumps(record, ensure_ascii=False))
        detached = subprocess.run(["git", "symbolic-ref", "-q", "HEAD"], cwd=path, capture_output=True)
        check("worktree 没有检出分支", detached.returncode != 0)
        check("对话移进 worktree", real(current.get("workingDirectory")) == real(path), current.get("workingDirectory"))
        check("未提交的改动带过去", read(os.path.join(path, "app.txt")) == "v2\n")
        check("未跟踪的文件带过去", read(os.path.join(path, "notes.txt")) == "draft\n")
        check(".worktreeinclude 列的忽略文件复制过去", read(os.path.join(path, ".env")) == "TOKEN=local-only\n")
        marker = read(os.path.join(path, "setup-ran.txt")) or ""
        source_seen, _, tree_seen = marker.partition("|")
        check("初始化脚本在 worktree 里跑、两个变量都对", real(source_seen) == real(repo) and real(tree_seen) == real(path),
              marker)
        check("本地的改动还在", read(os.path.join(repo, "app.txt")) == "v2\n")
        wait_for(lambda: not state()["isStreaming"], 180, 1)
        last = selected().get("lastReply") or {}
        check("回复在 worktree 里完成", last.get("status") == "complete", json.dumps(last, ensure_ascii=False)[:200])
        codex.settle()
        relay.snap(os.path.join(SHOTS, "01-worktree-chat.png"))

        print("顶栏环境动作")
        reply = relay.act("localEnvironment", op="runAction", conversationID=chat, index=0)
        check("运行动作", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
        ran = wait_for(lambda: read(os.path.join(path, "action-ran.txt")), 20)
        check("命令在 worktree 的终端里跑了", (ran or "").strip() == "action-ok", repr(ran))
        check("侧面板停在终端", state()["sidePanelOpen"] and state()["sidePanelTab"] == "terminal")
        codex.settle()
        relay.snap(os.path.join(SHOTS, "02-environment-action.png"))
        relay.act("sidePanel", open=False)

        print("交接到本地")
        git("checkout", "--", "app.txt", cwd=repo)
        os.remove(os.path.join(repo, "notes.txt"))
        write(os.path.join(path, "app.txt"), "v3\n")
        write(os.path.join(path, "feature.txt"), "feature\n")
        write(os.path.join(repo, "app.txt"), "local-edit\n")
        reply = relay.act("worktree", op="handoff", conversationID=chat, destination="local")
        check("本地有冲突改动时拒绝，并点名文件", not reply.get("ok") and "app.txt" in (reply.get("error") or ""),
              json.dumps(reply, ensure_ascii=False))
        check("拒绝后 worktree 不动", read(os.path.join(path, "app.txt")) == "v3\n"
              and real(selected().get("workingDirectory")) == real(path))
        check("拒绝后本地不动", read(os.path.join(repo, "app.txt")) == "local-edit\n")
        git("checkout", "--", "app.txt", cwd=repo)
        reply = relay.act("worktree", op="handoff", conversationID=chat, destination="local")
        check("交接到本地", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
        check("改动到了本地", read(os.path.join(repo, "app.txt")) == "v3\n"
              and read(os.path.join(repo, "feature.txt")) == "feature\n")
        check("对话回到本地目录", real(selected().get("workingDirectory")) == real(repo), selected().get("workingDirectory"))

        print("交接回 Worktree")
        reply = relay.act("worktree", op="handoff", conversationID=chat, destination="worktree")
        check("交接到 Worktree", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
        check("回到同一个 worktree", selected().get("managedWorktreeID") == tree_id
              and real(selected().get("workingDirectory")) == real(path))
        check("改动回到 worktree", read(os.path.join(path, "app.txt")) == "v3\n"
              and read(os.path.join(path, "feature.txt")) == "feature\n")
        porcelain = git("status", "--porcelain", cwd=repo)
        check("本地恢复干净", porcelain == "", porcelain)

        print("在此 worktree 新建对话")
        reply = relay.act("worktree", op="newChat", worktreeID=tree_id)
        sibling = reply.get("detail")
        check("新对话", reply.get("ok") and sibling, json.dumps(reply, ensure_ascii=False))
        if sibling:
            created.append(sibling)
            relay.act("select", conversationID=sibling)
            check("新对话在同一个 worktree", real(selected().get("workingDirectory")) == real(path))
            relay.act("delete", conversationID=sibling)
            created.remove(sibling)
            relay.act("select", conversationID=chat)

        print("删除与恢复")
        relay.act("sidebarOp", op="togglePin", conversationID=chat)
        reply = relay.act("worktree", op="delete", worktreeID=tree_id)
        check("置顶的对话在用时拒绝删除", not reply.get("ok") and os.path.isdir(path), json.dumps(reply, ensure_ascii=False))
        relay.act("sidebarOp", op="togglePin", conversationID=chat)
        reply = relay.act("worktree", op="delete", worktreeID=tree_id)
        check("删除", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
        record = tree(tree_id) or {}
        check("目录删掉、登记留快照", not os.path.exists(path) and record.get("deleted") and record.get("hasSnapshot"),
              json.dumps(record, ensure_ascii=False))
        check("清理脚本跑过", read(os.path.join(root, "cleanup-ran.txt")) == "cleaned")
        check("对话看到 worktree 已删除", selected()["worktreeDeleted"])
        codex.settle()
        relay.snap(os.path.join(SHOTS, "03-worktree-deleted.png"))
        reply = relay.act("worktree", op="restore", conversationID=chat)
        check("恢复", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
        check("工作回来了", read(os.path.join(path, "app.txt")) == "v3\n"
              and read(os.path.join(path, "feature.txt")) == "feature\n")
        check("对话重新绑定", real(selected().get("workingDirectory")) == real(path) and not selected()["worktreeDeleted"])

        print("归档对话会删除它的 worktree")
        relay.act("sidebarOp", op="toggleArchive", conversationID=chat)
        gone = wait_for(lambda: (tree(tree_id) or {}).get("deleted"), 30)
        check("归档后 worktree 删除并留快照", gone and not os.path.exists(path) and (tree(tree_id) or {}).get("hasSnapshot"),
              json.dumps(tree(tree_id), ensure_ascii=False))
        relay.act("sidebarOp", op="toggleArchive", conversationID=chat)
        relay.act("dismissUndo")
    finally:
        relay.act("stop")
        # A worktree whose chat is still winding down refuses deletion.
        wait_for(lambda: not relay.state()["isStreaming"], 30)
        relay.act("sidePanel", open=False)
        for tree_id in trees:
            record = tree(tree_id)
            if record and not record["deleted"]:
                relay.act("worktree", op="delete", worktreeID=tree_id)
        for conversation_id in created:
            relay.act("delete", conversationID=conversation_id)
        relay.act("dismissUndo")
        shutil.rmtree(root, ignore_errors=True)
        relay.act("sidePanel", open=baseline["sidePanelOpen"],
                  **({"tab": baseline["sidePanelTab"]} if baseline.get("sidePanelTab") else {}))
        if baseline.get("selectedID"):
            relay.act("select", conversationID=baseline["selectedID"])

    after = relay.state()
    check("场景对话已删除", after["conversationCount"] == baseline["conversationCount"],
          f"{baseline['conversationCount']} → {after['conversationCount']}")
    check("登记表里不留场景的 worktree", not any(t["id"] in trees for t in after["managedWorktrees"]),
          json.dumps([t for t in after["managedWorktrees"] if t["id"] in trees], ensure_ascii=False)[:300])


def main():
    global SHOTS
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token")
    parser.add_argument("--shots", default=SHOTS)
    args = parser.parse_args()
    SHOTS = args.shots
    relay = codex.Relay(args.host, args.port, codex.ompshot.resolve_token(args.token))
    check = codex.Checks()
    try:
        run(relay, check)
    except (RuntimeError, urllib.error.URLError, KeyError, StopIteration, IndexError, TypeError, ValueError) as error:
        check("场景跑完", False, f"{type(error).__name__}: {error}")
    print(f"\n{check.passed} 通过，{len(check.failed)} 失败；截图在 {SHOTS}")
    sys.exit(0 if not check.failed else 1)


if __name__ == "__main__":
    main()
