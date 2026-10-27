#!/usr/bin/env python3
"""Black-box scenario for the sidebar undo toast (Codex appUndo), run in the
background through the relay routes only.

Every action goes through the same model methods the sidebar menus use, then
the toast and the restored state are read back from /debug/state:

- rename, pin, archive, move into a section and out, delete a section with a
  chat in it, archive a whole section, then 撤销 for each;
- undo after the conversation was deleted reports why and changes nothing;
- 撤销 only ever pops an entry this scenario created (checked against the
  history first), so the user's own undo history is never touched.

No model request is made. The conversations and the section it creates are
deleted at the end and the previous selection is put back.

    python3 -I tools/ompshot/scenario_undo.py
"""

import argparse
import importlib.util
import json
import os
import sys
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("scenario_codex", os.path.join(HERE, "scenario_codex.py"))
codex = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(codex)


def run(relay, shots, check):
    baseline = relay.state()
    created = []
    section_ids = []

    def selected():
        return relay.state()["selected"]

    def toast():
        return relay.state().get("undoToast") or {}

    def undo(expected_toast):
        """Undoes the newest entry, only when it is the one this step made."""
        history = relay.state()["undoHistory"]
        if not history or history[0] != expected_toast:
            check(f"撤销前最新的一条是「{expected_toast}」", False, json.dumps(history[:3], ensure_ascii=False))
            return {}
        return relay.act("undo")

    def section(name):
        return next((g for g in relay.state()["groups"] if g["name"] == name and g["isSection"]), None)

    try:
        relay.act("newChat")
        first = relay.state()["selectedID"]
        created.append(first)
        original_title = selected()["title"]

        print("改名")
        relay.act("sidebarOp", op="rename", title="撤销场景")
        check("改名生效", selected()["title"] == "撤销场景")
        check("出现带撤销的提示", toast().get("offersUndo") is True and "撤销场景" in toast().get("message", ""),
              json.dumps(toast(), ensure_ascii=False))
        codex.settle()
        relay.snap(os.path.join(shots, "01-undo-toast.png"))
        reply = undo(toast().get("message"))
        check("撤销改名", reply.get("ok") and selected()["title"] == original_title, json.dumps(reply, ensure_ascii=False))
        check("提示换成撤销结果", toast().get("message") == "已恢复对话名称" and toast().get("offersUndo") is False,
              json.dumps(toast(), ensure_ascii=False))
        relay.act("sidebarOp", op="rename", title="撤销场景")

        print("置顶")
        relay.act("sidebarOp", op="togglePin")
        check("置顶生效", selected()["isPinned"])
        reply = undo(toast().get("message"))
        check("撤销置顶", reply.get("ok") and not selected()["isPinned"])

        print("移入分区再移出")
        relay.act("sidebarOp", op="createSection", name="撤销场景分区")
        group = section("撤销场景分区")
        check("新建分区", group is not None)
        if group:
            section_ids.append(group["id"])
            relay.act("sidebarOp", op="move", groupID=group["id"])
            check("移入分区", selected().get("groupID") == group["id"])
            reply = undo(toast().get("message"))
            check("撤销移动：回到不在分组里", reply.get("ok") and selected().get("groupID") is None)

            print("删除带对话的分区")
            relay.act("sidebarOp", op="move", groupID=group["id"])
            relay.act("sidebarOp", op="deleteGroup", groupID=group["id"])
            check("分区删掉，对话移出分组", section("撤销场景分区") is None and selected().get("groupID") is None)
            reply = undo(toast().get("message"))
            restored = section("撤销场景分区")
            check("撤销删除：分区回来、对话回到分区里",
                  reply.get("ok") and restored is not None and selected().get("groupID") == (restored or {}).get("id"),
                  json.dumps({"reply": reply, "group": restored, "conv": selected().get("groupID")}, ensure_ascii=False))
            if restored:
                section_ids[-1] = restored["id"]
                group = restored

            print("整个分区归档")
            relay.act("newChat")
            second = relay.state()["selectedID"]
            created.append(second)
            relay.act("sidebarOp", op="move", conversationID=second, groupID=group["id"])
            relay.act("sidebarOp", op="archiveSection", groupID=group["id"])
            archived = toast().get("message", "")
            relay.act("select", conversationID=first)
            check("两条都归档", selected()["isArchived"] and "2" in archived, archived)
            reply = undo(archived)
            relay.act("select", conversationID=first)
            first_back = not selected()["isArchived"]
            relay.act("select", conversationID=second)
            second_back = not selected()["isArchived"]
            check("撤销批量归档：两条都恢复", reply.get("ok") and first_back and second_back)
            check("批量撤销的结果文字", toast().get("message") == "已恢复 2 个对话", json.dumps(toast(), ensure_ascii=False))

        print("单条归档")
        # Archiving the selected chat moves the selection, as in the app.
        relay.act("sidebarOp", op="toggleArchive", conversationID=first)
        relay.act("select", conversationID=first)
        check("归档生效", selected()["isArchived"])
        reply = undo(toast().get("message"))
        relay.act("select", conversationID=first)
        check("撤销归档", reply.get("ok") and not selected()["isArchived"])

        print("目标已删除时撤销")
        relay.act("sidebarOp", op="rename", conversationID=first, title="先改的名字")
        rename_toast = toast().get("message")
        relay.act("newChat")
        doomed = relay.state()["selectedID"]
        created.append(doomed)
        relay.act("sidebarOp", op="rename", title="马上删除")
        doomed_toast = toast().get("message")
        relay.act("delete", conversationID=doomed)
        created.remove(doomed)
        reply = undo(doomed_toast)
        check("说明无法撤销", not reply.get("ok") and "无法撤销" in (reply.get("error") or ""),
              json.dumps(reply, ensure_ascii=False))
        history = relay.state()["undoHistory"]
        check("失败的撤销不留在历史里，更早的一条成了最新", history[:1] == [rename_toast],
              json.dumps(history[:3], ensure_ascii=False))

        relay.act("dismissUndo")
        check("关掉提示", relay.state().get("undoToast") is None)
    finally:
        for conversation_id in created:
            relay.act("delete", conversationID=conversation_id)
        for group_id in section_ids:
            if any(g["id"] == group_id for g in relay.state()["groups"]):
                relay.act("sidebarOp", op="deleteGroup", groupID=group_id)
        relay.act("dismissUndo")
        if baseline.get("selectedID"):
            relay.act("select", conversationID=baseline["selectedID"])

    after = relay.state()
    check("场景对话已删除", after["conversationCount"] == baseline["conversationCount"],
          f"{baseline['conversationCount']} → {after['conversationCount']}")
    check("场景分区已删除", [g["id"] for g in after["groups"]] == [g["id"] for g in baseline["groups"]])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token")
    parser.add_argument("--shots", default=".artifacts/shots/undo")
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
