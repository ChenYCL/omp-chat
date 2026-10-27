#!/usr/bin/env python3
"""Live black-box scenario for composer mentions, driven through the relay
routes only, with the app in the background.

Tools are switched off in the scenario's conversations, so the model cannot
read anything itself: a code word it answers with can only have reached it
through a mention block. For each kind:

- @ file: the list finds `notes.md` in the bound git folder and leaves out a
  `.gitignore`d file; picking it puts a token in the draft and a chip in
  `draftMentions`; the reply carries the code word only that file holds;
- $ skill: a repository skill under `.agents/skills` is listed with its
  source, and the model follows the SKILL.md body it has never seen;
- @ chat: a second conversation quotes the first one's transcript;
- @ tab: a side-panel browser tab on a local page the scenario serves;
- a vanished file, a binary file and a path outside the folder become notes
  and never block the send, and their contents never leave the Mac.

Every write names a conversation the scenario created. They, the browser tab,
the local server and the temporary folder are removed at the end, and the
previous selection and side panel are put back. Calls the configured model.

    python3 -I tools/ompshot/scenario_mentions.py
"""

import argparse
import functools
import http.server
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


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def run(relay, shots, check):
    baseline = relay.state()
    root = f"/private/tmp/omp-mentions-{os.getpid()}"
    work = os.path.join(root, "work")
    site = os.path.join(root, "site")
    os.makedirs(os.path.join(work, ".agents", "skills", "papaya"))
    os.makedirs(site)
    with open(os.path.join(work, "notes.md"), "w", encoding="utf-8") as handle:
        handle.write("# 备忘\n\n本项目的暗号是 MANGO-5531。\n")
    with open(os.path.join(work, "ignored-notes.md"), "w", encoding="utf-8") as handle:
        handle.write("不该被列出\n")
    with open(os.path.join(work, ".gitignore"), "w", encoding="utf-8") as handle:
        handle.write("ignored-notes.md\n")
    with open(os.path.join(work, "bin.dat"), "wb") as handle:
        handle.write(b"BINSECRET\x00\x01\x02")
    with open(os.path.join(root, "outside.txt"), "w", encoding="utf-8") as handle:
        handle.write("OUTSIDE-SECRET\n")
    with open(os.path.join(work, ".agents", "skills", "papaya", "SKILL.md"), "w", encoding="utf-8") as handle:
        handle.write("---\nname: papaya\ndescription: 场景用的技能，回答一个固定口令\n---\n\n"
                     "当用户说「执行 papaya」时，只回复 PAPAYA-8806 这一串字符，不要加任何别的字。\n")
    for args in (("init", "-q", "-b", "main"), ("config", "user.email", "scenario@example.com"),
                 ("config", "user.name", "scenario")):
        codex.git(*args, cwd=work)
    codex.git("add", ".", cwd=work)
    codex.git("commit", "-q", "-m", "init", cwd=work)
    with open(os.path.join(site, "page.html"), "w", encoding="utf-8") as handle:
        handle.write("<!doctype html><html><head><meta charset='utf-8'><title>番石榴页面</title></head>"
                     "<body><h1>标签页暗号</h1><p>这个页面的暗号是 GUAVA-7342。</p></body></html>")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=site))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    page = f"http://127.0.0.1:{server.server_address[1]}/page.html"

    created = []
    base_tabs = [tab["id"] for tab in baseline["browserTabs"]]

    def state():
        return relay.state()

    def selected():
        return relay.state()["selected"]

    def focus(conversation_id):
        """Selects a scenario conversation and refuses to go on otherwise."""
        relay.act("select", conversationID=conversation_id)
        if relay.state()["selectedID"] != conversation_id:
            raise RuntimeError("could not select the scenario conversation")

    def set_draft(conversation_id, text):
        focus(conversation_id)
        relay.act("setDraft", text=text)

    def search(conversation_id, query, trigger):
        reply = relay.act("mentionSearch", conversationID=conversation_id, query=query, trigger=trigger)
        return json.loads(reply.get("detail") or "{}") if reply.get("ok") else {}

    def pick(conversation_id, typed, candidate):
        """Types `typed` (ending in the @… / $… query) and picks the candidate."""
        set_draft(conversation_id, typed)
        return relay.act("pickMention", conversationID=conversation_id, token=candidate["token"])

    def send_draft(conversation_id, extra):
        """Types `extra` after the draft and presses send, as a user would:
        the field holds readable mentions, the send button turns them into
        tokens."""
        focus(conversation_id)
        draft = relay.state()["draft"]
        # Picking leaves a space after the mention so typing can go on.
        set_draft(conversation_id, draft + (extra.lstrip(" ") if draft.endswith(" ") else extra))
        reply = relay.act("sendDraft", conversationID=conversation_id)
        after = relay.state()
        check("发送后输入框和提及标签清空", not after["draft"] and not after["draftMentions"],
              json.dumps({"draft": after["draft"], "chips": after["draftMentions"]}, ensure_ascii=False))
        return reply

    def answer(conversation_id, timeout=180):
        focus(conversation_id)
        wait_for(lambda: not relay.state()["isStreaming"], timeout, 1)
        return selected().get("lastReply") or {}

    def last_user():
        """The newest user message as the bubble shows it."""
        users = [m for m in selected()["transcript"] if m["role"] == "user"]
        return users[-1] if users else {}

    def new_chat():
        relay.act("newChat")
        conversation_id = relay.state()["selectedID"]
        if not conversation_id or selected()["messageCount"] != 0:
            raise RuntimeError("newChat did not select a fresh conversation")
        created.append(conversation_id)
        relay.act("setAccess", conversationID=conversation_id, access="chat")
        return conversation_id

    try:
        first = new_chat()
        relay.act("continueIn", conversationID=first, mode="folder", path=work)
        relay.act("setAccess", conversationID=first, access="chat")
        check("场景对话关掉了工具", selected()["access"] == "chat" and not selected()["toolsEnabled"],
              json.dumps({k: selected().get(k) for k in ("access", "toolsEnabled")}))

        print("@ 文件：列表、选择、发送")
        found = search(first, "notes", "@")
        files = [c for c in found.get("candidates", []) if c["kind"] == "file"]
        notes = next((c for c in files if c["title"] == "notes.md"), None)
        check("文件列表里有 notes.md", notes is not None, json.dumps(found, ensure_ascii=False)[:400])
        check(".gitignore 忽略的文件不列出", not any(c["title"] == "ignored-notes.md" for c in files),
              json.dumps([c["title"] for c in files], ensure_ascii=False))
        check("没有报「无法搜索文件」", found.get("fileSearchFailed") is False)
        if notes:
            reply = pick(first, "看 @notes", notes)
            draft = state()
            check("选择后输入框里显示 @notes.md，正在输入的 @notes 被替换",
                  reply.get("ok") and draft["draft"] == "看 @notes.md " and "](file:" not in draft["draft"],
                  json.dumps({"reply": reply, "draft": draft["draft"]}, ensure_ascii=False))
            check("输入框上方的标签显示 @notes.md", draft["draftMentions"] == ["@notes.md"],
                  json.dumps(draft["draftMentions"], ensure_ascii=False))
            codex.settle()
            relay.snap(os.path.join(shots, "01-file-mention-chip.png"))
            written = "看 @notes.md 里写的暗号是什么？只回复暗号本身。"
            reply = send_draft(first, " 里写的暗号是什么？只回复暗号本身。")
            check("发送成功", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
            last = answer(first)
            check("模型从文件内容里答出暗号", "MANGO-5531" in last.get("text", ""), last.get("text", "")[:200])
            bubble = last_user()
            check("气泡只显示用户写的字", bubble.get("text") == written, json.dumps(bubble, ensure_ascii=False)[:300])
            check("文件作为气泡下的标签附上", bubble.get("attached") == ["@notes.md"] and not bubble.get("mentionNotes"),
                  json.dumps(bubble, ensure_ascii=False)[:300])

            print("改坏提及：变回普通文字")
            pick(first, "再看 @notes", notes)
            set_draft(first, state()["draft"].replace("@notes.md", "@notes.mdx"))
            broken = state()
            check("改成 @notes.mdx 后不再是提及", broken["draftMentions"] == [] and "@notes.mdx" in broken["draft"],
                  json.dumps({"draft": broken["draft"], "chips": broken["draftMentions"]}, ensure_ascii=False))
            set_draft(first, "")

        print("$ 技能：仓库里的 SKILL.md")
        found = search(first, "papa", "$")
        skill = next((c for c in found.get("candidates", []) if c["kind"] == "skill" and c["title"] == "papaya"), None)
        check("技能列表里有 papaya 并标出来源", skill is not None and skill["badge"],
              json.dumps(found, ensure_ascii=False)[:400])
        if skill:
            pick(first, "$papa", skill)
            check("技能标签", state()["draftMentions"] == ["$papaya"], json.dumps(state()["draftMentions"], ensure_ascii=False))
            send_draft(first, " 执行 papaya")
            last = answer(first)
            check("模型按技能正文回答", "PAPAYA-8806" in last.get("text", ""), last.get("text", "")[:200])
            bubble = last_user()
            check("气泡里不出现 SKILL.md 正文", bubble.get("text") == "$papaya 执行 papaya"
                  and bubble.get("attached") == ["$papaya"], json.dumps(bubble, ensure_ascii=False)[:300])

        print("@ 对话：引用另一个对话")
        second = new_chat()
        # A plain title: the @… query must not contain spaces or another @.
        relay.act("sidebarOp", op="rename", conversationID=first, title="芒果备忘")
        found = search(second, "芒果", "@")
        chat = next((c for c in found.get("candidates", []) if c["kind"] == "chat" and c["token"].endswith(f"chat:{first})")), None)
        check("对话列表里有第一个对话", chat is not None, json.dumps(found, ensure_ascii=False)[:400])
        if chat:
            pick(second, "@芒果", chat)
            send_draft(second, " 这个被提及的对话里，助手回复过的以 MANGO 开头的暗号是什么？只回复暗号。")
            last = answer(second)
            check("模型从被提及的对话里答出暗号", "MANGO-5531" in last.get("text", ""), last.get("text", "")[:200])
            check("对话作为标签附上", last_user().get("attached") == ["@芒果备忘"],
                  json.dumps(last_user(), ensure_ascii=False)[:300])

        print("@ 标签页：侧面板浏览器里的本地页面")
        focus(second)
        relay.act("sidePanel", open=True, tab="browser")
        relay.act("browserOpenTab", url=page)
        loaded = wait_for(lambda: any(t["title"] == "番石榴页面" for t in relay.state()["browserTabs"]), 20)
        check("标签页加载出本地页面", loaded, json.dumps(relay.state()["browserTabs"], ensure_ascii=False)[:300])
        found = search(second, "番石榴", "@")
        tab = next((c for c in found.get("candidates", []) if c["kind"] == "tab"), None)
        check("标签页出现在提及列表", tab is not None, json.dumps(found, ensure_ascii=False)[:400])
        if tab:
            pick(second, "@番石榴", tab)
            codex.settle()
            relay.snap(os.path.join(shots, "02-tab-mention.png"))
            send_draft(second, " 这个页面上的暗号是什么？只回复暗号。")
            last = answer(second)
            check("模型从页面文字里答出暗号", "GUAVA-7342" in last.get("text", ""), last.get("text", "")[:200])
            bubble = last_user()
            check("标签页作为标签附上、页面文字不在气泡里",
                  len(bubble.get("attached") or []) == 1 and "GUAVA" not in bubble.get("text", ""),
                  json.dumps(bubble, ensure_ascii=False)[:300])

        print("拿不到的提及：变成说明，不挡发送，内容不外传")
        focus(first)
        tokens = "[@gone.md](file:gone.md) [@bin.dat](file:bin.dat) [@outside.txt](file:../outside.txt)"
        set_draft(first, tokens)
        check("三个手写标记都被认出", state()["draftMentions"] == ["@gone.md", "@bin.dat", "@outside.txt"],
              json.dumps(state()["draftMentions"], ensure_ascii=False))
        reply = send_draft(first, " 只回复一个字：好")
        check("照常发出", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
        last = answer(first)
        bubble = last_user()
        check("回复正常完成", last.get("status") == "complete", json.dumps(last, ensure_ascii=False)[:200])
        notes_text = "\n".join(bubble.get("mentionNotes") or [])
        check("气泡下的提及说明点名三个文件",
              all(name in notes_text for name in ("gone.md", "bin.dat", "outside.txt")), notes_text[:400])
        check("三个都没有附上，气泡正文不带说明",
              not bubble.get("attached") and "提及说明" not in bubble.get("text", ""),
              json.dumps(bubble, ensure_ascii=False)[:400])
        check("二进制和目录外的内容没有外传",
              "BINSECRET" not in json.dumps(bubble, ensure_ascii=False)
              and "OUTSIDE-SECRET" not in json.dumps(bubble, ensure_ascii=False))
        codex.settle()
        relay.snap(os.path.join(shots, "03-mention-notes.png"))
    finally:
        relay.act("stop")
        for tab in relay.state()["browserTabs"]:
            if tab["id"] not in base_tabs:
                relay.act("browserCloseTab", tabID=tab["id"])
        for conversation_id in created:
            relay.act("delete", conversationID=conversation_id)
        server.shutdown()
        shutil.rmtree(root, ignore_errors=True)
        relay.act("sidePanel", open=baseline["sidePanelOpen"],
                  **({"tab": baseline["sidePanelTab"]} if baseline.get("sidePanelTab") else {}))
        if baseline.get("selectedID"):
            relay.act("select", conversationID=baseline["selectedID"])

    after = relay.state()
    check("场景对话已删除", after["conversationCount"] == baseline["conversationCount"],
          f"{baseline['conversationCount']} → {after['conversationCount']}")
    check("浏览器标签已还原", [t["id"] for t in after["browserTabs"]] == base_tabs)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token")
    parser.add_argument("--shots", default=".artifacts/shots/mentions")
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
