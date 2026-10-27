#!/usr/bin/env python3
"""Background black-box scenario for 从其他 AI 应用导入 (Codex externalAgentImport),
driven through the relay routes only.

Everything is read from and written to a fixture "home" under /private/tmp:
the user's real ~/.claude and ~/.cursor are never touched. The fixture has a
Claude Code setup (global CLAUDE.md, a skill, a slash command, an MCP server
with a secret in its env, hooks, an agent), two projects with CLAUDE.md (one of
them already has an AGENTS.md) and one recorded session, plus a Cursor MCP
config.

Checks:
- the scan finds both apps, lists every item, explains what it will not
  import, and never shows the MCP secret;
- importing the skill, the command, the projects' instructions and the session
  copies the skill, turns the command into a skill, writes AGENTS.md only
  where none existed, and brings the session over as a chat bound to its
  folder with the user's and the assistant's words;
- a second import skips everything it already brought over.

Global instructions and MCP servers are only checked in the scan: importing
them changes this app's own 自定义指令 and MCP settings. The chat, any sidebar
project the import created and the fixture are removed at the end.

    python3 -I tools/ompshot/scenario_import.py
"""

import argparse
import importlib.util
import json
import os
import shutil
import sys
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("scenario_codex", os.path.join(HERE, "scenario_codex.py"))
codex = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(codex)

SECRET = "SECRET-FIXTURE-7781"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def build_fixture(home):
    proj = os.path.join(home, "projects", "proj")
    keep = os.path.join(home, "projects", "keep")
    write(os.path.join(home, ".claude.json"), json.dumps({
        "mcpServers": {
            "fixture-memory": {
                "command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory@2.0.0"],
                "env": {"API_TOKEN": SECRET},
            },
        },
        "projects": {proj: {"hasTrustDialogAccepted": True}, keep: {}},
    }))
    write(os.path.join(home, ".claude", "CLAUDE.md"), "# 全局规则\n\n回答前先确认需求。\n")
    write(os.path.join(home, ".claude", "skills", "fixture-skill", "SKILL.md"),
          "---\nname: fixture-skill\ndescription: 导入场景的技能\n---\n\n照做：输出 FIXTURE-SKILL。\n")
    write(os.path.join(home, ".claude", "commands", "fixture-cmd.md"),
          "---\ndescription: 导入场景的命令\n---\n\n按顺序执行：$ARGUMENTS\n")
    write(os.path.join(home, ".claude", "agents", "reviewer.md"), "# 审查代理\n")
    write(os.path.join(home, ".claude", "settings.json"),
          json.dumps({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "guard.sh"}]}]}}))
    write(os.path.join(proj, "CLAUDE.md"), "# 项目规则\n\n提交说明用中文写。\n")
    write(os.path.join(keep, "CLAUDE.md"), "# 别的规则\n")
    write(os.path.join(keep, "AGENTS.md"), "# 已有的 AGENTS\n")
    encoded = proj.replace("/", "-")
    lines = [
        {"type": "user", "cwd": proj, "timestamp": "2026-10-20T10:00:00.000Z",
         "message": {"role": "user", "content": "导入场景的第一句话：把订单同步到对账表"}},
        {"type": "assistant", "cwd": proj, "timestamp": "2026-10-20T10:00:05.000Z",
         "message": {"role": "assistant", "content": [
             {"type": "text", "text": "好的，先看看对账表的结构。"},
             {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}},
         ]}},
        {"type": "user", "cwd": proj, "timestamp": "2026-10-20T10:00:06.000Z", "isMeta": True,
         "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "a.csv"}]}},
        {"type": "assistant", "cwd": proj, "timestamp": "2026-10-20T10:00:09.000Z",
         "message": {"role": "assistant", "content": [{"type": "text", "text": "同步完成，共 3 条。"}]}},
    ]
    write(os.path.join(home, ".claude", "projects", encoded, "s1.jsonl"),
          "\n".join(json.dumps(line, ensure_ascii=False) for line in lines) + "\n")
    write(os.path.join(home, ".cursor", "mcp.json"),
          json.dumps({"mcpServers": {"cursor-fetch": {"command": "uvx", "args": ["mcp-server-fetch"]}}}))
    return proj, keep


def run(relay, check):
    baseline = relay.state()
    base_groups = {g["id"] for g in baseline["groups"]}
    base_imported = {c["id"] for c in baseline.get("importedConversations", [])}
    root = f"/private/tmp/omp-import-{os.getpid()}"
    home = os.path.join(root, "home")
    proj, keep = build_fixture(home)
    created = []
    try:
        print("扫描")
        reply = relay.act("externalImport", home=home, op="scan")
        check("扫描成功", reply.get("ok"), json.dumps(reply, ensure_ascii=False)[:300])
        scan = json.loads(reply.get("detail") or "{}")
        entries = scan.get("entries", [])
        kinds = {e["kind"] for e in entries}
        check("找到 Claude Code 和 Cursor", len(scan.get("providers", [])) == 2, json.dumps(scan.get("providers")))
        for kind in ("instructions", "mcpServers", "skills", "commands", "sessions", "projects"):
            check(f"列出 {kind}", kind in kinds, json.dumps(sorted(kinds)))
        not_imported = {n["kind"] for n in scan.get("notImported", [])}
        check("说明不导入的钩子和子代理", {"hooks", "agents"} <= not_imported,
              json.dumps(scan.get("notImported", []), ensure_ascii=False)[:300])
        check("扫描结果里没有 MCP 密钥", SECRET not in reply.get("detail", ""))
        keep_rows = [e for e in entries if e["kind"] == "projects" and e["title"] == "keep"]
        check("已有 AGENTS.md 的项目不会被覆盖", keep_rows and all(e.get("skippedReason") for e in keep_rows),
              json.dumps(keep_rows, ensure_ascii=False)[:300])

        chosen = [e["id"] for e in entries if not e.get("skippedReason") and (
            e["kind"] in ("skills", "commands", "sessions")
            or (e["kind"] == "projects" and e["title"] == "proj")
        )]
        print("导入技能、命令、项目规则、会话")
        reply = relay.act("externalImport", home=home, op="run", entryIDs=chosen)
        lines = json.loads(reply.get("detail") or "[]")
        picked = [l for l in lines if l["id"] in chosen]
        others = [l for l in lines if l["id"] not in chosen]
        # A project row can carry a second, informational line (the imported
        # chat was filed under it); every chosen id needs one imported line.
        check("选中的都导入了", reply.get("ok") and not any(l["failed"] for l in lines)
              and all(any(l["id"] == i and l.get("note") is None for l in picked) for i in chosen),
              json.dumps([{k: l.get(k) for k in ("id", "note")} for l in picked], ensure_ascii=False)[-700:])
        check("没选的一条也没导入", all(l.get("note") for l in others), json.dumps(others, ensure_ascii=False)[:400])
        skill = os.path.join(home, ".agents", "skills", "fixture-skill", "SKILL.md")
        check("技能复制到 ~/.agents/skills", os.path.isfile(skill) and "FIXTURE-SKILL" in open(skill, encoding="utf-8").read())
        command = os.path.join(home, ".agents", "skills", "fixture-cmd", "SKILL.md")
        check("命令变成技能", os.path.isfile(command) and "$ARGUMENTS" in open(command, encoding="utf-8").read())
        agents = os.path.join(proj, "AGENTS.md")
        check("项目里写出 AGENTS.md", os.path.isfile(agents) and "提交说明用中文写" in open(agents, encoding="utf-8").read())
        check("已有的 AGENTS.md 原样不动", open(os.path.join(keep, "AGENTS.md"), encoding="utf-8").read() == "# 已有的 AGENTS\n")

        state = relay.state()
        imported = [c for c in state.get("importedConversations", []) if c["id"] not in base_imported]
        created = [c["id"] for c in imported]
        check("会话导入成一个对话", len(imported) == 1, json.dumps(imported, ensure_ascii=False))
        if imported:
            chat = imported[0]
            check("对话绑定到项目目录", os.path.realpath(chat.get("workingDirectory") or "") == os.path.realpath(proj),
                  json.dumps(chat, ensure_ascii=False))
            check("标题取第一句话", chat["title"].startswith("导入场景的第一句话"), chat["title"])
            relay.act("select", conversationID=chat["id"])
            transcript = relay.state()["selected"]["transcript"]
            texts = [(m["role"], m["text"]) for m in transcript]
            check("用户和助手的话都在", ("user", "导入场景的第一句话：把订单同步到对账表") in texts
                  and any(r == "assistant" and "同步完成" in t for r, t in texts),
                  json.dumps(texts, ensure_ascii=False)[:400])
            check("工具调用的原始输出没有原样塞进来", not any("tool_result" in t for _, t in texts))
            codex.settle()
            relay.snap(os.path.join(SHOTS, "01-imported-chat.png"))

        print("再导入一次")
        reply = relay.act("externalImport", home=home, op="run", entryIDs=chosen)
        lines = json.loads(reply.get("detail") or "[]")
        check("第二次全部跳过", lines and all(l.get("note") for l in lines), json.dumps(lines, ensure_ascii=False)[:500])
        again = [c for c in relay.state().get("importedConversations", []) if c["id"] not in base_imported]
        check("没有重复的对话", len(again) == len(imported))
        created = [c["id"] for c in again]
    finally:
        for conversation_id in created:
            relay.act("delete", conversationID=conversation_id)
        for group in relay.state()["groups"]:
            if group["id"] not in base_groups:
                relay.act("sidebarOp", op="deleteGroup", groupID=group["id"])
        shutil.rmtree(root, ignore_errors=True)
        relay.act("dismissUndo")
        if baseline.get("selectedID"):
            relay.act("select", conversationID=baseline["selectedID"])

    after = relay.state()
    check("场景对话已删除", after["conversationCount"] == baseline["conversationCount"],
          f"{baseline['conversationCount']} → {after['conversationCount']}")
    check("导入新建的侧栏项目已删除", {g["id"] for g in after["groups"]} == base_groups)


SHOTS = ".artifacts/shots/import"


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
