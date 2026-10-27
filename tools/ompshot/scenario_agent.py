#!/usr/bin/env python3
"""Live black-box scenario for the agent runtime, run in the background.

Drives the installed OMPChat through its relay routes only (/debug/action,
/debug/state, /debug/snapshot) and asks the configured model to use tools in a
temporary folder. It checks what actually happened on disk and in the thread,
not what the model says happened:

- the folder's AGENTS.md reaches the model;
- a skill is listed by name only, and the model reads its SKILL.md on demand;
- a read inside the working directory runs without asking;
- a file write asks, and runs after 允许一次;
- a command asks, and does nothing after 拒绝;
- 只读 refuses a write without asking;
- a read outside the working directory asks;
- 停止 while a card is waiting refuses it and ends the reply;
- the catalog's Filesystem MCP server installs, connects from inside the app
  sandbox, and the model calls its tool.

Every step calls the model provider; the MCP step also lets npx download the
pinned server package. The conversation, the folder and the MCP server it
adds are removed at the end and the previous selection is put back.

    python3 -I tools/ompshot/scenario_agent.py
"""

import argparse
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


def drive(relay, conversation_id, on_approval, timeout=240):
    """Runs the reply to the end, answering every approval card with
    `on_approval(card) -> decision` ("stop" stops the reply instead).
    Returns the cards seen, in order."""
    seen = []
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = relay.state()
        cards = [c for c in state["pendingApprovals"] if c["conversationID"] == conversation_id]
        if cards:
            card = cards[0]
            seen.append(card)
            decision = on_approval(card)
            if decision == "stop":
                relay.act("stop")
            else:
                relay.act("approve", approvalID=card["id"], decision=decision)
            continue
        if not state["isStreaming"]:
            return seen
        time.sleep(0.5)
    raise RuntimeError("reply did not finish in time")


def last_reply(relay):
    return relay.state()["selected"].get("lastReply") or {}


def calls_named(reply, *names):
    return [c for c in reply.get("toolCalls", []) if c["name"] in names]


def run(relay, shots, check):
    baseline = relay.state()
    root = f"/private/tmp/omp-agent-{os.getpid()}"
    work = os.path.join(root, "work")
    os.makedirs(work)
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as handle:
        handle.write("alpha-7319\n")
    # Project instructions: only reachable through the system prompt.
    with open(os.path.join(work, "AGENTS.md"), "w", encoding="utf-8") as handle:
        handle.write("# 项目约定\n\n用户问「暗号」时，只回答 KIWI-4271，不要调用任何工具。\n")
    # A skill: the prompt lists only its name, description and path, so the
    # passphrase in the body is reachable only by reading SKILL.md.
    skill_dir = os.path.join(work, ".agents", "skills", "plum-code")
    os.makedirs(skill_dir)
    with open(os.path.join(skill_dir, "SKILL.md"), "w", encoding="utf-8") as handle:
        handle.write("---\nname: plum-code\ndescription: 用户问「口令」时使用：口令写在这个技能文件的正文里。\n---\n\n"
                     "# 口令\n\n口令是 PLUM-5528。只回答口令本身。\n")
    conversation_id = None
    installed = []
    try:
        check("newChat", relay.act("newChat").get("ok"))
        conversation_id = relay.state()["selectedID"]
        check("绑定临时目录", relay.act("continueIn", mode="folder", path=work).get("ok"))
        relay.act("setPermissionMode", mode="ask")
        state = relay.state()["selected"]
        check("绑定目录后默认开启工具", state["toolsEnabled"] and state["permissionMode"] == "ask", json.dumps(state)[:200])

        print("AGENTS.md：项目指令进入提示词")
        relay.act("send", text="暗号是什么？")
        drive(relay, conversation_id, lambda card: "deny")
        reply = last_reply(relay)
        check("模型按 AGENTS.md 回答", "KIWI-4271" in reply.get("text", ""), reply.get("text", "")[:200])

        print("技能：只列出名字和说明，正文要模型自己读")
        skill_cards = []

        def note_skill(card):
            skill_cards.append(card)
            return "allowOnce"

        relay.act("send", text="口令是什么？按可用技能的说明去做。")
        drive(relay, conversation_id, note_skill)
        reply = last_reply(relay)
        skill_reads = [c for c in calls_named(reply, "read_file") if c["arguments"].find("SKILL.md") >= 0]
        check("模型读取了 SKILL.md", bool(skill_reads), json.dumps(reply, ensure_ascii=False)[:300])
        check("读取技能文件不用批准", not [c for c in skill_cards if c["toolName"] == "read_file"],
              json.dumps(skill_cards, ensure_ascii=False))
        check("模型按技能正文回答", "PLUM-5528" in reply.get("text", ""), reply.get("text", "")[:200])

        print("读取：工作目录内不询问")
        relay.act("send", text="用 read_file 工具读取 notes.txt，然后只回复文件里的那一行内容，不要别的字。")
        cards = drive(relay, conversation_id, lambda card: "allowOnce")
        reply = last_reply(relay)
        reads = calls_named(reply, "read_file")
        check("模型调用了 read_file", bool(reads), json.dumps(reply, ensure_ascii=False)[:300])
        check("读取没有弹批准", not [c for c in cards if c["toolName"] == "read_file"], json.dumps(cards, ensure_ascii=False))
        check("工具结果是文件内容", any("alpha-7319" in (c["result"] or "") for c in reads))
        check("回复引用了文件内容", "alpha-7319" in reply.get("text", ""), reply.get("text", "")[:200])

        print("写文件：询问后允许一次")
        target = os.path.join(work, "hello.txt")
        shot = {"taken": False}

        def allow_write(card):
            if not shot["taken"]:
                codex.settle()
                relay.snap(os.path.join(shots, "01-approval-card.png"))
                shot["taken"] = True
            check("写文件弹出批准卡片", card["toolName"] == "write_file" and card["risk"] == "write",
                  json.dumps(card, ensure_ascii=False))
            check("批准前文件还不存在", not os.path.exists(target))
            return "allowOnce"

        relay.act("send", text="用 write_file 工具在当前工作目录创建 hello.txt，内容只有一行 OMP_AGENT_OK，然后回复「完成」。")
        cards = drive(relay, conversation_id, allow_write)
        check("出现过批准卡片", bool(cards))
        content = open(target, encoding="utf-8").read() if os.path.exists(target) else ""
        check("允许后文件真的写出", "OMP_AGENT_OK" in content, repr(content))
        codex.settle()
        relay.snap(os.path.join(shots, "02-after-write.png"))

        print("运行命令：询问后拒绝")
        denied = os.path.join(work, "denied.txt")
        risks = []

        def deny(card):
            risks.append((card["toolName"], card["risk"]))
            return "deny"

        relay.act("send", text="用 shell 工具运行 `touch denied.txt`。如果被拒绝，就回复「已被拒绝」。")
        cards = drive(relay, conversation_id, deny)
        check("命令弹出批准卡片", ("shell", "execute") in risks, str(risks))
        check("拒绝后命令没有运行", not os.path.exists(denied))
        shells = calls_named(last_reply(relay), "shell")
        check("模型收到了拒绝", any("拒绝" in (c["result"] or "") for c in shells),
              json.dumps(shells, ensure_ascii=False)[:300])

        print("只读模式：不询问直接拒绝写入")
        relay.act("setPermissionMode", mode="readOnly")
        readonly = os.path.join(work, "ro.txt")
        relay.act("send", text="用 write_file 工具创建 ro.txt，内容 x。被拒绝就回复「只读」。")
        cards = drive(relay, conversation_id, lambda card: "deny")
        check("只读模式下没有弹卡片", not cards, json.dumps(cards, ensure_ascii=False))
        check("只读模式下文件没写出", not os.path.exists(readonly))
        writes = calls_named(last_reply(relay), "write_file")
        check("模型收到了只读拒绝", bool(writes) and all(c["result"] for c in writes),
              json.dumps(writes, ensure_ascii=False)[:300])
        relay.act("setPermissionMode", mode="ask")

        print("读取工作目录外：要询问")
        outside = []

        def note_outside(card):
            outside.append(card)
            return "deny"

        relay.act("send", text="用 read_file 工具读取 /etc/hosts 的前两行。被拒绝就回复「拒绝」。")
        drive(relay, conversation_id, note_outside)
        check("目录外读取弹出卡片且不是普通读取",
              any(c["toolName"] == "read_file" and c["risk"] != "read" for c in outside),
              json.dumps({"cards": outside, "reply": last_reply(relay)}, ensure_ascii=False)[:500])

        print("等待批准时停止")
        stopped = os.path.join(work, "stop.txt")
        relay.act("send", text="用 shell 工具运行 `echo stopped > stop.txt`。")
        cards = drive(relay, conversation_id, lambda card: "stop")
        state = relay.state()
        check("停止后有过卡片", bool(cards), json.dumps(last_reply(relay), ensure_ascii=False)[:500])
        check("停止后没有等待中的卡片", not [c for c in state["pendingApprovals"] if c["conversationID"] == conversation_id])
        check("停止后不再生成", not state["isStreaming"])
        check("停止后命令没有运行", not os.path.exists(stopped))

        print("联网 + 工具：同一个请求里带 web_search 和函数工具")
        relay.act("setWebSearch", enabled=True)
        try:
            check("联网已打开", relay.state()["webSearchEnabled"])
            relay.act("send", text="用 read_file 工具读取 notes.txt，然后只回复文件里的那一行内容。")
            drive(relay, conversation_id, lambda card: "allowOnce")
            state = relay.state()
            reply = last_reply(relay)
            check("同一请求没有被网关拒绝", reply.get("status") == "complete" and not reply.get("error")
                  and not state.get("errorMessage"),
                  json.dumps({"reply": reply, "banner": state.get("errorMessage")}, ensure_ascii=False)[:400])
            check("联网打开时模型仍能调用函数工具",
                  any("alpha-7319" in (c["result"] or "") for c in calls_named(reply, "read_file")),
                  json.dumps(reply, ensure_ascii=False)[:300])
        finally:
            relay.act("setWebSearch", enabled=False)

        print("MCP：从目录安装 Filesystem 服务器并让模型调用")
        before_ids = {s["id"] for s in relay.state()["mcpServers"]}
        reply = relay.act("mcpInstall", entryID="filesystem", values={"directories": [work]})
        check("安装目录条目", reply.get("ok"), reply.get("error", ""))
        added = [s for s in relay.state()["mcpServers"] if s["id"] not in before_ids]
        installed.extend(s["id"] for s in added)
        server = added[0] if added else {}
        # First run downloads the pinned package through npx.
        deadline = time.time() + 240
        while server and time.time() < deadline and server["status"] in ("connecting", "disabled"):
            time.sleep(2)
            server = next((s for s in relay.state()["mcpServers"] if s["id"] == server["id"]), {})
        check("服务器在沙盒应用里连上", server.get("status") == "ready" and (server.get("toolCount") or 0) > 0,
              json.dumps(server, ensure_ascii=False)[:400])
        relay.act("openSettings", section="mcp")
        codex.settle()
        settings = next((w for w in relay.windows() if w["title"] == "OMPChat Settings" and w["visible"]), None)
        if settings:
            relay.snap(os.path.join(shots, "03-mcp-settings.png"), settings["number"])
        relay.act("closeSettings")
        if server.get("status") == "ready":
            relay.act("send", text=f"用名字以 mcp__ 开头的文件系统工具读取 {work}/notes.txt，只回复文件里的那一行内容。不要用 read_file。")
            drive(relay, conversation_id, lambda card: "allowOnce")
            calls = [c for c in last_reply(relay).get("toolCalls", []) if c["name"].startswith("mcp__")]
            check("模型调用了 MCP 工具", bool(calls), json.dumps(last_reply(relay), ensure_ascii=False)[:300])
            check("MCP 工具返回了文件内容", any("alpha-7319" in (c["result"] or "") for c in calls),
                  json.dumps(calls, ensure_ascii=False)[:300])
            codex.settle()
            relay.snap(os.path.join(shots, "04-mcp-call.png"))
    finally:
        for server_id in installed:
            relay.act("mcpRemove", serverID=server_id)
        if conversation_id:
            relay.act("delete", conversationID=conversation_id)
        shutil.rmtree(root, ignore_errors=True)
        if baseline.get("selectedID"):
            relay.act("select", conversationID=baseline["selectedID"])

    after = relay.state()
    check("场景对话已删除", after["conversationCount"] == baseline["conversationCount"],
          f"{baseline['conversationCount']} → {after['conversationCount']}")
    check("MCP 服务器已移除", {s["id"] for s in after["mcpServers"]} == {s["id"] for s in baseline["mcpServers"]})


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token")
    parser.add_argument("--shots", default=".artifacts/shots/agent")
    args = parser.parse_args()
    relay = codex.Relay(args.host, args.port, codex.ompshot.resolve_token(args.token))
    check = codex.Checks()
    try:
        run(relay, args.shots, check)
    except (RuntimeError, urllib.error.URLError, KeyError, StopIteration, IndexError) as error:
        check("场景跑完", False, f"{type(error).__name__}: {error}")
    print(f"\n{check.passed} 通过，{len(check.failed)} 失败；截图在 {args.shots}")
    sys.exit(0 if not check.failed else 1)


if __name__ == "__main__":
    main()
