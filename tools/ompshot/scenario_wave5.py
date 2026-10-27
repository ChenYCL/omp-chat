#!/usr/bin/env python3
"""Background black-box scenario for scheduled tasks, file references and
用 Codex 审查, driven through the relay routes only.

Without --live (no model request):
- a daily task is listed with its summary and next run; a one-time task in
  the past and a task without a title are refused with the editor's text;
  pause clears the next run, resume brings it back, delete removes it;
- 打开文件 at a line opens the side panel's 文件 tab and the tab takes the
  request;
- 用 Codex 审查 refuses a clean repository and a thread without a folder.

With --live (calls the configured model):
- a one-time task due a minute from now is fired by the app's own timer:
  a new conversation gets the prompt and a reply, and the task completes;
- 立即运行 on a task attached to a conversation sends into that conversation;
- a review of a repository with a planted bug opens a read-only thread
  bound to the repository that names the file.

Everything it creates is deleted and the previous selection is put back.

    python3 -I tools/ompshot/scenario_wave5.py [--live]
"""

import argparse
import datetime
import importlib.util
import json
import os
import shutil
import sys
import time
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("scenario_codex", os.path.join(HERE, "scenario_codex.py"))
codex = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(codex)


def iso(delta_seconds):
    moment = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=delta_seconds)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def wait_for(predicate, timeout, step=1.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


def run(relay, shots, check, live):
    baseline = relay.state()
    root = f"/private/tmp/omp-wave5-{os.getpid()}"
    os.makedirs(root)
    created_conversations = []
    created_tasks = []

    def tasks():
        return relay.state()["scheduledTasks"]

    def task_named(title):
        return next((t for t in tasks() if t["title"] == title), None)

    def add_task(**fields):
        before = {t["id"] for t in tasks()}
        reply = relay.act("scheduledTask", op="add", **fields)
        new = [t for t in tasks() if t["id"] not in before]
        created_tasks.extend(t["id"] for t in new)
        return reply, (new[0] if new else None)

    try:
        print("定时任务：新建 / 校验 / 暂停 / 继续 / 删除")
        reply, daily = add_task(title="场景日报", prompt="总结今天", schedule={"kind": "daily", "hour": 9, "minute": 30})
        check("新建每天的任务", reply.get("ok") and daily is not None, json.dumps(reply, ensure_ascii=False))
        if daily:
            check("计划摘要", daily["summary"] == "每天 09:30", daily["summary"])
            check("下次运行有日期", daily["status"] == "active" and daily["nextRunAt"]
                  and daily["nextRunLabel"].endswith("09:30"), json.dumps(daily, ensure_ascii=False))
            codex.settle()
            relay.snap(os.path.join(shots, "01-scheduled-task.png"))
            relay.act("scheduledTask", op="pause", taskID=daily["id"])
            paused = task_named("场景日报")
            check("暂停后没有下次运行", paused["status"] == "paused" and paused["nextRunLabel"] == "未安排",
                  json.dumps(paused, ensure_ascii=False))
            reply = relay.act("scheduledTask", op="resume", taskID=daily["id"])
            resumed = task_named("场景日报")
            check("继续后重新排上", reply.get("ok") and resumed["status"] == "active" and resumed["nextRunAt"],
                  json.dumps(resumed, ensure_ascii=False))
            relay.act("scheduledTask", op="delete", taskID=daily["id"])
            created_tasks.remove(daily["id"])
            check("删除", task_named("场景日报") is None)

        reply, past = add_task(title="过去", prompt="x", schedule={"kind": "once", "date": iso(-3600)})
        check("一次性任务时间已过被拒绝", not reply.get("ok") and past is None and "时间已过" in (reply.get("error") or ""),
              json.dumps(reply, ensure_ascii=False))
        reply, untitled = add_task(title="  ", prompt="x", schedule={"kind": "everyHours", "interval": 2})
        check("没有标题被拒绝", not reply.get("ok") and untitled is None and "标题" in (reply.get("error") or ""),
              json.dumps(reply, ensure_ascii=False))
        reply, fast = add_task(title="太频繁", prompt="x", schedule={"kind": "everyMinutes", "interval": 1})
        check("每 1 分钟低于下限被拒绝", not reply.get("ok") and fast is None, json.dumps(reply, ensure_ascii=False))
        check("不存在的任务报错", not relay.act("scheduledTask", op="runNow", taskID="00000000-0000-0000-0000-000000000000").get("ok"))

        print("文件引用：打开到指定行")
        work = os.path.join(root, "work")
        os.makedirs(work)
        target_file = os.path.join(work, "calc.swift")
        with open(target_file, "w", encoding="utf-8") as handle:
            handle.write("".join(f"let line{n} = {n}\n" for n in range(1, 41)))
        relay.act("newChat")
        chat = relay.state()["selectedID"]
        created_conversations.append(chat)
        relay.act("continueIn", mode="folder", path=work)
        check("openFile 成功", relay.act("openFile", path=target_file, line=30).get("ok"))
        picked = wait_for(lambda: relay.state().get("pendingFileRequest") is None, 5, 0.3)
        state = relay.state()
        check("侧面板在文件标签并取走了请求",
              picked and state["sidePanelOpen"] and state["sidePanelTab"] == "files",
              json.dumps({k: state.get(k) for k in ("sidePanelOpen", "sidePanelTab", "pendingFileRequest")}, ensure_ascii=False))
        codex.settle()
        relay.snap(os.path.join(shots, "02-open-file-line-30.png"))

        print("用 Codex 审查：没有改动 / 没有目录")
        repo = os.path.join(root, "repo")
        os.makedirs(repo)
        for args in (("init", "-q", "-b", "main"), ("config", "user.email", "scenario@example.com"),
                     ("config", "user.name", "scenario")):
            codex.git(*args, cwd=repo)
        with open(os.path.join(repo, "stats.py"), "w", encoding="utf-8") as handle:
            handle.write("def average(values):\n    return sum(values) / len(values)\n")
        codex.git("add", ".", cwd=repo)
        codex.git("commit", "-q", "-m", "init", cwd=repo)
        relay.act("continueIn", mode="folder", path=repo)
        before = relay.state()["conversationCount"]
        reply = relay.act("codeReview")
        check("干净的仓库不开审查", not reply.get("ok") and "没有可审查的改动" in (reply.get("error") or "")
              and relay.state()["conversationCount"] == before, json.dumps(reply, ensure_ascii=False))
        relay.act("continueIn", mode="local")
        reply = relay.act("codeReview")
        check("没有工作目录不开审查", not reply.get("ok"), json.dumps(reply, ensure_ascii=False))

        if live:
            print("用 Codex 审查：有问题的改动")
            relay.act("continueIn", mode="folder", path=repo)
            with open(os.path.join(repo, "stats.py"), "w", encoding="utf-8") as handle:
                handle.write("def average(values):\n    return sum(values) / (len(values) - 1)\n")
            reply = relay.act("codeReview")
            check("开出审查对话", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
            review = relay.state()
            review_id = review["selectedID"]
            if review_id != chat:
                created_conversations.append(review_id)
            selected = review["selected"]
            check("审查对话：只读、开工具、绑定仓库",
                  selected["isCodeReview"] and selected["access"] == "readOnly" and selected["toolsEnabled"]
                  and selected["workingDirectory"] == repo and selected["title"].startswith("审查"),
                  json.dumps({k: selected.get(k) for k in ("title", "access", "toolsEnabled", "workingDirectory", "isCodeReview")},
                             ensure_ascii=False))
            wait_for(lambda: not relay.state()["isStreaming"], 240, 2)
            selected = relay.state()["selected"]
            text = (selected.get("lastReply") or {}).get("text", "")
            check("审查结论提到出问题的文件", "stats.py" in text, text[:300])
            check("审查算作有报告", selected.get("reviewOutcome") == "reported", str(selected.get("reviewOutcome")))
            codex.settle()
            relay.snap(os.path.join(shots, "03-code-review.png"))

            print("定时任务：到点由应用自己的计时器触发")
            reply, once = add_task(title="场景定时", prompt="只回复四个字：定时任务好",
                                   schedule={"kind": "once", "date": iso(70)})
            check("新建一分钟后的一次性任务", reply.get("ok") and once is not None, json.dumps(reply, ensure_ascii=False))
            if once:
                fired = wait_for(lambda: (task_named("场景定时") or {}).get("runCount") == 1, 200, 2)
                done = task_named("场景定时") or {}
                check("到点运行了一次", fired, json.dumps(done, ensure_ascii=False))
                run_id = done.get("lastRunConversationID")
                if run_id:
                    created_conversations.append(run_id)
                    wait_for(lambda: not relay.state()["isStreaming"], 180, 2)
                    relay.act("select", conversationID=run_id)
                    selected = relay.state()["selected"]
                    text = (selected.get("lastReply") or {}).get("text", "")
                    check("新对话里有提示词和回复", selected["messageCount"] >= 2 and "定时任务" in text,
                          json.dumps({"title": selected["title"], "count": selected["messageCount"], "text": text[:120]},
                                     ensure_ascii=False))
                    check("新对话以任务名命名", selected["title"].startswith("场景定时"), selected["title"])
                check("一次性任务运行后完成", (task_named("场景定时") or {}).get("status") == "completed")
                codex.settle()
                relay.snap(os.path.join(shots, "04-scheduled-run.png"))

            print("定时任务：发到当前对话，立即运行")
            relay.act("select", conversationID=chat)
            relay.act("continueIn", mode="local")
            count = relay.state()["selected"]["messageCount"]
            reply, attached = add_task(title="场景心跳", prompt="只回复两个字：收到",
                                       schedule={"kind": "everyHours", "interval": 6},
                                       target={"kind": "attached", "conversationID": chat})
            check("新建附加到对话的任务", reply.get("ok") and attached is not None, json.dumps(reply, ensure_ascii=False))
            if attached:
                reply = relay.act("scheduledTask", op="runNow", taskID=attached["id"])
                check("立即运行", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
                wait_for(lambda: not relay.state()["isStreaming"], 180, 2)
                relay.act("select", conversationID=chat)
                selected = relay.state()["selected"]
                check("提示词和回复进了同一个对话", selected["messageCount"] >= count + 2,
                      f"{count} → {selected['messageCount']}")
                check("任务记下这次运行", (task_named("场景心跳") or {}).get("lastRunConversationID") == chat)
    finally:
        for task_id in created_tasks:
            relay.act("scheduledTask", op="delete", taskID=task_id)
        relay.act("stop")
        for conversation_id in created_conversations:
            relay.act("delete", conversationID=conversation_id)
        shutil.rmtree(root, ignore_errors=True)
        relay.act("sidePanel", open=baseline["sidePanelOpen"], **({"tab": baseline["sidePanelTab"]} if baseline.get("sidePanelTab") else {}))
        if baseline.get("selectedID"):
            relay.act("select", conversationID=baseline["selectedID"])

    after = relay.state()
    check("场景对话已删除", after["conversationCount"] == baseline["conversationCount"],
          f"{baseline['conversationCount']} → {after['conversationCount']}")
    check("场景任务已删除", [t["id"] for t in after["scheduledTasks"]] == [t["id"] for t in baseline["scheduledTasks"]])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--live", action="store_true", help="也跑要调用模型的部分")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token")
    parser.add_argument("--shots", default=".artifacts/shots/wave5")
    args = parser.parse_args()
    relay = codex.Relay(args.host, args.port, codex.ompshot.resolve_token(args.token))
    check = codex.Checks()
    try:
        run(relay, args.shots, check, args.live)
    except (RuntimeError, urllib.error.URLError, KeyError, StopIteration, IndexError, TypeError) as error:
        check("场景跑完", False, f"{type(error).__name__}: {error}")
    print(f"\n{check.passed} 通过，{len(check.failed)} 失败；截图在 {args.shots}")
    sys.exit(0 if not check.failed else 1)


if __name__ == "__main__":
    main()
