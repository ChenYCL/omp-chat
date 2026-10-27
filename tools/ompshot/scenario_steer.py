#!/usr/bin/env python3
"""Live black-box scenario for follow-ups during a running reply (steering)
and context compaction, run in the background through the relay routes.

It calls the configured model. What it checks is what lands in the thread,
not what the model says:

- a follow-up sent while an approval card waits is queued, the card and the
  reply survive, and after 允许一次 the follow-up reaches the model as a user
  message inside the same reply;
- 停止 keeps a queued follow-up but holds it (nothing is sent), and 编辑
  moves it back into the composer draft;
- 立即发送 interrupts the waiting reply and sends the follow-up now;
- 压缩上下文 replaces the earlier turns with a summary that is smaller, and a
  message sent while it runs waits and is sent when it finishes.

The conversation and folder it creates are deleted at the end, the draft is
cleared and the previous selection is put back.

    python3 -I tools/ompshot/scenario_steer.py
"""

import argparse
import importlib.util
import json
import os
import shutil
import sys
import threading
import time
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("scenario_codex", os.path.join(HERE, "scenario_codex.py"))
codex = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(codex)


def wait_for(predicate, timeout, step=0.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


def run(relay, shots, check):
    baseline = relay.state()
    root = f"/private/tmp/omp-steer-{os.getpid()}"
    work = os.path.join(root, "work")
    os.makedirs(work)
    conversation_id = None

    def selected():
        return relay.state()["selected"]

    def cards():
        return [c for c in relay.state()["pendingApprovals"] if c["conversationID"] == conversation_id]

    def user_texts():
        return [m["text"] for m in selected()["transcript"] if m["role"] == "user"]

    def finish(timeout=240):
        """Lets the reply run to its end, refusing any further card."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            waiting = cards()
            if waiting:
                relay.act("approve", approvalID=waiting[0]["id"], decision="deny")
                continue
            if not relay.state()["isStreaming"] and not selected()["queued"]:
                return True
            time.sleep(0.5)
        return False

    def say(text):
        """Sends into the scenario's own conversation, never the selected one."""
        if not conversation_id:
            raise RuntimeError("no scenario conversation yet")
        return relay.act("send", conversationID=conversation_id, text=text)

    def start_with_card(command):
        say(f"用 shell 工具运行 `{command}`，然后只回复命令的输出。")
        return wait_for(cards, 120)

    try:
        relay.act("newChat")
        conversation_id = relay.state()["selectedID"]
        # Every send below names this conversation; never the user's.
        if not conversation_id or selected()["messageCount"] != 0:
            raise RuntimeError("newChat did not select a fresh conversation")
        relay.act("continueIn", mode="folder", path=work)
        relay.act("setAccess", access="ask")

        # A long first turn: compaction only applies a summary that is
        # shorter than the turns it replaces.
        material = "请先记住下面这段项目背景，之后可能会问到。这一条只回复「已记住」三个字，不要调用工具。\n" + \
            "".join(f"第{n}条：模块{n}负责处理第{n}类订单的对账，上游是接口服务，下游是报表服务，出错时要回滚到上一个快照。\n"
                    for n in range(1, 31))
        say(material)
        check("背景材料那一轮走完", finish())

        print("等待批准时插话：排队，批准后进同一个回复")
        waiting = start_with_card("echo steer-ok")
        check("出现批准卡片", bool(waiting), json.dumps(selected().get("lastReply"), ensure_ascii=False)[:300])
        follow_up = "另外，17 加 25 等于几？在回复的最后一行只写这个数字。"
        reply = say(follow_up)
        state = selected()
        check("插话进了队列", reply.get("ok") and [q["text"] for q in state["queued"]] == [follow_up],
              json.dumps({"reply": reply, "queued": state["queued"]}, ensure_ascii=False))
        check("插话没有打断回复，卡片还在", relay.state()["isStreaming"] and bool(cards()))
        check("排队时还没进对话", follow_up not in user_texts())
        codex.settle()
        relay.snap(os.path.join(shots, "01-queued-while-card.png"))
        if waiting:
            relay.act("approve", approvalID=waiting[0]["id"], decision="allowOnce")
        finished = finish()
        state = selected()
        check("回复走完，队列清空", finished and not state["queued"], json.dumps(state["queued"], ensure_ascii=False))
        texts = user_texts()
        check("插话作为用户消息进了对话", follow_up in texts, json.dumps(texts, ensure_ascii=False)[:300])
        transcript = state["transcript"]
        index = next((i for i, m in enumerate(transcript) if m["text"] == follow_up), -1)
        later_assistant = [m for m in transcript[index + 1:] if m["role"] == "assistant"] if index >= 0 else []
        check("插话之后模型接着回答", any("42" in m["text"] for m in later_assistant),
              json.dumps([m["text"][:120] for m in later_assistant], ensure_ascii=False))
        check("没有「追问没有收到回复」", not any(m.get("error") for m in transcript if m["role"] == "user"))

        print("停止：队列保留但不发，编辑放回输入框")
        waiting = start_with_card("echo stop-case")
        held_text = "这条会被停住"
        say(held_text)
        before = user_texts()
        relay.act("stop")
        stopped = wait_for(lambda: not relay.state()["isStreaming"] and not cards(), 20)
        state = selected()
        check("停止后不再回复、没有卡片", stopped)
        check("队列还在且被停住", [(q["text"], q["held"]) for q in state["queued"]] == [(held_text, True)],
              json.dumps(state["queued"], ensure_ascii=False))
        time.sleep(3)
        check("停住的消息没有自己发出", held_text not in user_texts() and user_texts() == before)
        queued_id = state["queued"][0]["id"] if state["queued"] else ""
        relay.act("queued", conversationID=conversation_id, queuedID=queued_id, op="edit")
        state = relay.state()
        check("编辑：回到输入框，队列清空", held_text in state["draft"] and not state["selected"]["queued"],
              json.dumps({"draft": state["draft"], "queued": state["selected"]["queued"]}, ensure_ascii=False))
        relay.act("setDraft", text="")

        print("立即发送：打断等待中的回复")
        waiting = start_with_card("echo now-case")
        now_text = "不用运行了，只回复四个字：立即发送"
        say(now_text)
        queued_id = (selected()["queued"] or [{}])[0].get("id", "")
        reply = relay.act("queued", conversationID=conversation_id, queuedID=queued_id, op="sendNow")
        check("立即发送成功", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
        check("原来的卡片被收掉", wait_for(lambda: not cards() or cards()[0]["id"] != waiting[0]["id"], 10) if waiting else False)
        check("消息马上进了对话", now_text in user_texts())
        finished = finish()
        last = selected().get("lastReply") or {}
        check("新回复走完并可停止结束", finished and last.get("status") == "complete", json.dumps(last, ensure_ascii=False)[:300])

        print("压缩上下文：压缩时插话会等压缩结束")
        result = {}
        compactor = threading.Thread(target=lambda: result.update(relay.act("compact", conversationID=conversation_id)))
        compactor.start()
        compacting = wait_for(lambda: selected()["isCompacting"], 15, 0.2)
        check("开始压缩", compacting)
        during = "压缩之后的第一个问题：这个对话里运行过哪些 echo 命令？只列命令。"
        if compacting:
            reply = say(during)
            check("压缩时插话排队", reply.get("ok") and [q["text"] for q in selected()["queued"]] == [during],
                  json.dumps({"reply": reply, "queued": selected()["queued"]}, ensure_ascii=False))
            codex.settle()
            relay.snap(os.path.join(shots, "02-compacting.png"))
        compactor.join(180)
        check("压缩成功", result.get("ok"), json.dumps(result, ensure_ascii=False))
        compaction = selected().get("compaction") or {}
        check("有摘要且比原来小", compaction.get("summary") and compaction.get("tokensAfter", 1e9) < compaction.get("tokensBefore", 0),
              json.dumps({k: compaction.get(k) for k in ("tokensBefore", "tokensAfter")}))
        if compacting:
            finished = finish()
            texts = user_texts()
            check("压缩完插话自动发出", finished and during in texts and not selected()["queued"])
            last = selected().get("lastReply") or {}
            check("压缩后的回答还记得前面的命令", "echo" in last.get("text", "") and "steer-ok" in last.get("text", ""),
                  last.get("text", "")[:300])
        check("对话里的消息都还在", len(selected()["transcript"]) >= 6)
        codex.settle()
        relay.snap(os.path.join(shots, "03-compacted.png"))
    finally:
        relay.act("stop")
        if conversation_id:
            # The draft belongs to the selected conversation; clear the
            # scenario's own, not the user's.
            relay.act("select", conversationID=conversation_id)
            relay.act("setDraft", text="")
            relay.act("delete", conversationID=conversation_id)
        shutil.rmtree(root, ignore_errors=True)
        if baseline.get("selectedID"):
            relay.act("select", conversationID=baseline["selectedID"])

    after = relay.state()
    check("场景对话已删除", after["conversationCount"] == baseline["conversationCount"],
          f"{baseline['conversationCount']} → {after['conversationCount']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token")
    parser.add_argument("--shots", default=".artifacts/shots/steer")
    args = parser.parse_args()
    relay = codex.Relay(args.host, args.port, codex.ompshot.resolve_token(args.token))
    check = codex.Checks()
    try:
        run(relay, args.shots, check)
    except (RuntimeError, urllib.error.URLError, KeyError, StopIteration, IndexError, TypeError) as error:
        check("场景跑完", False, f"{type(error).__name__}: {error}")
    print(f"\n{check.passed} 通过，{len(check.failed)} 失败；截图在 {args.shots}")
    sys.exit(0 if not check.failed else 1)


if __name__ == "__main__":
    main()
