#!/usr/bin/env python3
"""Black-box scenario for approving the Mac's tool cards from a phone.

Plays a paired phone: everything the phone would do goes to the relay's LAN
address (`/input`, `/snapshot`, `/command`), which is the only way a phone
reaches the Mac. Setup and checks use the loopback-only /debug routes, which
the LAN address must refuse. The app stays in the background.

What it checks, against the real model:

- /debug/* is refused (403) on the LAN address and answers on loopback;
- with 「允许手机访问文件与终端」 off, a phone-started reply in a 完全访问
  conversation still stops at an approval card, the card says the phone cannot
  allow it, an allow from the phone is refused and reported, and nothing is
  written; a deny from the phone ends the reply;
- the phone can never grant 始终允许 (400);
- with the switch on, the same reply runs without asking, and in 每次询问
  mode the phone can allow a card and the file lands on disk.

Every step that sends a message calls the model provider. The conversation and
the temporary folder are removed and the switch is put back.

    python3 -I tools/ompshot/scenario_remote_approval.py [--lan-host IP]
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


def lan_address():
    for interface in ("en0", "en1"):
        result = subprocess.run(["ipconfig", "getifaddr", interface], capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    return None


def wait_for(condition, timeout, step=1.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(step)
    return None


def run(mac, phone, shots, check):
    baseline = mac.state()
    root = f"/private/tmp/omp-phone-{os.getpid()}"
    work = os.path.join(root, "work")
    os.makedirs(work)
    conversation_id = None
    try:
        status, _, _ = phone.call("/debug/state")
        check("LAN 地址上 /debug 被拒绝（403）", status == 403, f"HTTP {status}")
        status, _, _ = phone.call("/debug/action", {"action": "stop"})
        check("LAN 地址上 /debug/action 被拒绝（403）", status == 403, f"HTTP {status}")
        status, _, _ = phone.call("/pair")
        check("LAN 地址上配对接口照常可用", status == 200, f"HTTP {status}")

        mac.act("setPhoneAccess", enabled=False)
        check("手机访问已关", mac.state()["phoneAccess"] is False)
        check("newChat", mac.act("newChat").get("ok"))
        conversation_id = mac.state()["selectedID"]
        check("绑定临时目录", mac.act("continueIn", mode="folder", path=work).get("ok"))
        mac.act("setPermissionMode", mode="full")
        check("对话设为完全访问", mac.state()["selected"]["permissionMode"] == "full")

        print("手机访问关闭：手机发起的回复仍要批准")
        target = os.path.join(work, "phone.txt")
        status, _, _ = phone.call("/input", {
            "conversationID": conversation_id,
            "text": "用 write_file 工具在当前工作目录创建 phone.txt，内容只有一行 PHONE_OK，然后回复「完成」。"})
        check("手机发出消息", status == 200, f"HTTP {status}")

        def pending():
            snapshot = phone.snapshot()
            return [a for a in snapshot.get("approvals", []) if a["conversationID"] == conversation_id]

        cards = wait_for(pending, 120)
        check("完全访问的对话里，手机发起的写操作仍弹出批准卡片", bool(cards), "snapshot 里没有 approvals")
        if cards:
            card = cards[0]
            check("手机看到的是 write_file 写入卡片", card["toolName"] == "write_file" and card["risk"] == "write",
                  json.dumps(card, ensure_ascii=False)[:200])
            check("卡片标明手机不能批准", card["canApprove"] is False)
            check("批准前文件不存在", not os.path.exists(target))
            mac.act("openSettings", section="remoteControl")
            codex.settle()
            mac.act("closeSettings")
            codex.settle()
            mac.snap(os.path.join(shots, "01-card-on-mac.png"))

            status, _, _ = phone.call("/command", {"kind": "approve", "approvalID": card["id"],
                                                   "decision": "allowOnce", "requestID": "req-allow-1"})
            check("手机的批准指令被收下", status == 200, f"HTTP {status}")
            failure = wait_for(lambda: next((f for f in phone.snapshot().get("commandFailures", [])
                                             if f["requestID"] == "req-allow-1"), None), 20)
            check("拒绝原因回到手机（shell_disabled）", bool(failure) and failure["error"] == "shell_disabled",
                  json.dumps(failure, ensure_ascii=False))
            check("被拒绝的批准没有生效：卡片还在、文件没写", bool(pending()) and not os.path.exists(target))

            status, _, _ = phone.call("/command", {"kind": "approve", "approvalID": card["id"],
                                                   "decision": "allowAlways", "requestID": "req-always"})
            check("手机不能给出始终允许（400）", status == 400, f"HTTP {status}")
            check("始终允许被拒后卡片没变", bool(pending()) and not os.path.exists(target))

            status, _, _ = phone.call("/command", {"kind": "approve", "approvalID": card["id"],
                                                   "decision": "deny", "requestID": "req-deny"})
            check("手机的拒绝被收下", status == 200)
            # The model often tries again after a refusal; the phone keeps
            # refusing (deny is always allowed) until the reply ends.
            denied = {card["id"]}
            deadline = time.time() + 180
            while time.time() < deadline and mac.state()["isStreaming"]:
                for retry in pending():
                    if retry["id"] not in denied:
                        denied.add(retry["id"])
                        phone.call("/command", {"kind": "approve", "approvalID": retry["id"],
                                                "decision": "deny", "requestID": f"req-deny-{len(denied)}"})
                time.sleep(1)
            check("手机一直拒绝，回复结束", not mac.state()["isStreaming"], f"拒绝了 {len(denied)} 张卡片")
            check("拒绝后没有留下卡片", not pending())
            check("拒绝后文件仍不存在", not os.path.exists(target))

        print("手机访问打开：同一个请求直接执行")
        mac.act("setPhoneAccess", enabled=True)
        check("手机访问已开", mac.state()["phoneAccess"] is True)
        phone.call("/input", {
            "conversationID": conversation_id,
            "text": "用 write_file 工具在当前工作目录创建 phone.txt，内容只有一行 PHONE_OK，然后回复「完成」。"})
        check("回复跑完", bool(wait_for(lambda: not mac.state()["isStreaming"], 180)))
        content = open(target, encoding="utf-8").read() if os.path.exists(target) else ""
        check("打开后完全访问的对话不再询问，文件写出", "PHONE_OK" in content, repr(content))
        check("没有留下等待的卡片", not mac.state()["pendingApprovals"])

        print("每次询问：手机可以批准")
        mac.act("setPermissionMode", mode="ask")
        second = os.path.join(work, "second.txt")
        phone.call("/input", {
            "conversationID": conversation_id,
            "text": "用 write_file 工具在当前工作目录创建 second.txt，内容只有一行 SECOND_OK，然后回复「完成」。"})
        cards = wait_for(pending, 120)
        check("每次询问下弹出卡片", bool(cards))
        if cards:
            card = cards[0]
            check("手机访问打开后卡片标明手机可以批准", card["canApprove"] is True)
            check("批准前文件不存在", not os.path.exists(second))
            status, _, _ = phone.call("/command", {"kind": "approve", "approvalID": card["id"],
                                                   "decision": "allowOnce", "requestID": "req-ok"})
            check("手机批准被收下", status == 200)
            check("批准后回复跑完", bool(wait_for(lambda: not mac.state()["isStreaming"], 180)))
            content = open(second, encoding="utf-8").read() if os.path.exists(second) else ""
            check("手机批准后文件真的写出", "SECOND_OK" in content, repr(content))
            check("批准后卡片消失", not pending())
            codex.settle()
            mac.snap(os.path.join(shots, "02-after-phone-approval.png"))

        status, _, _ = phone.call("/command", {"kind": "approve", "approvalID": "no-such-card",
                                               "decision": "allowOnce", "requestID": "req-ghost"})
        check("不存在的卡片：指令被收下", status == 200)
        failure = wait_for(lambda: next((f for f in phone.snapshot().get("commandFailures", [])
                                         if f["requestID"] == "req-ghost"), None), 20)
        check("不存在的卡片：原因是 not_found", bool(failure) and failure["error"] == "not_found",
              json.dumps(failure, ensure_ascii=False))
    finally:
        mac.act("setPhoneAccess", enabled=baseline.get("phoneAccess", False))
        if conversation_id:
            mac.act("delete", conversationID=conversation_id)
        shutil.rmtree(root, ignore_errors=True)
        if baseline.get("selectedID"):
            mac.act("select", conversationID=baseline["selectedID"])

    after = mac.state()
    check("场景对话已删除", after["conversationCount"] == baseline["conversationCount"],
          f"{baseline['conversationCount']} → {after['conversationCount']}")
    check("手机访问开关已还原", after["phoneAccess"] == baseline["phoneAccess"])


class Phone(codex.Relay):
    def snapshot(self):
        status, body, _ = self.call("/snapshot")
        return json.loads(body) if status == 200 else {}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lan-host", help="这台 Mac 的局域网地址；缺省取 en0 / en1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token")
    parser.add_argument("--shots", default=".artifacts/shots/remote-approval")
    args = parser.parse_args()
    lan = args.lan_host or lan_address()
    if not lan:
        sys.exit("找不到局域网地址：用 --lan-host 传入（回环地址不能代表手机）")
    token = codex.ompshot.resolve_token(args.token)
    mac = codex.Relay("127.0.0.1", args.port, token)
    phone = Phone(lan, args.port, token)
    check = codex.Checks()
    try:
        run(mac, phone, args.shots, check)
    except (RuntimeError, urllib.error.URLError, KeyError, StopIteration, IndexError) as error:
        check("场景跑完", False, f"{type(error).__name__}: {error}")
    print(f"\n{check.passed} 通过，{len(check.failed)} 失败；截图在 {args.shots}")
    sys.exit(0 if not check.failed else 1)


if __name__ == "__main__":
    main()
