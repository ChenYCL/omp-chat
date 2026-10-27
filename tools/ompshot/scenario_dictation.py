#!/usr/bin/env python3
"""Background black-box scenario for composer dictation, without a microphone.

The installed app transcribes audio files made with macOS `say` through the
same on-device recognizer the composer's mic button uses (`transcribeFile`),
so nothing asks for microphone access and no audio leaves the Mac. Checks:

- Chinese speech lands in the draft as Chinese;
- English speech is merged after text already in the draft, never over it;
- silence, a missing file and a language without an on-device model fail
  with the composer's own error texts and leave the draft as it was;
- 设置 → 语音 shows the 听写语言 picker.

The live microphone path is not exercised here: it needs the user to grant
microphone access first. Everything the scenario creates is removed and the
previous selection is put back.

    python3 -I tools/ompshot/scenario_dictation.py
"""

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("scenario_codex", os.path.join(HERE, "scenario_codex.py"))
codex = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(codex)


def say(voice, text, path):
    subprocess.run(["say", "-v", voice, "-o", path, text], check=True)


def run(relay, shots, check):
    baseline = relay.state()
    root = f"/private/tmp/omp-dictation-{os.getpid()}"
    os.makedirs(root)
    chinese = os.path.join(root, "zh.aiff")
    english = os.path.join(root, "en.aiff")
    silent = os.path.join(root, "silent.aiff")
    # The bare name `Flo` picks an English Flo, which renders Chinese text as
    # 0.02 s of nothing; the voice has to be named with its language.
    say("Flo (Chinese (China mainland))", "你好，这是一次听写测试", chinese)
    say("Samantha", "Hello, this is a dictation test.", english)
    say("Samantha", "[[slnc 2000]]", silent)
    conversation_id = None

    def draft():
        return relay.state()["draft"]

    def transcribe(path, locale=None):
        fields = {"conversationID": conversation_id, "path": path}
        if locale:
            fields["locale"] = locale
        return relay.act("transcribeFile", **fields)

    try:
        relay.act("newChat")
        conversation_id = relay.state()["selectedID"]
        if not conversation_id or relay.state()["selected"]["messageCount"] != 0:
            raise RuntimeError("newChat did not select a fresh conversation")

        print("中文转写进草稿")
        reply = transcribe(chinese, "zh-CN")
        check("转写成功", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
        text = draft()
        # A synthetic voice is not transcribed word for word (这是一次听写 has
        # come back as 就是一寸写真); what matters is Chinese in, Chinese out.
        han = sum(1 for ch in text if "\u4e00" <= ch <= "\u9fff")
        check("草稿里是中文的听写结果", text.startswith("你好") and han >= 6
              and not any(ch.isascii() and ch.isalpha() for ch in text), repr(text))
        check("听写状态回到完成", relay.state()["dictation"] in ("done", "idle"), relay.state()["dictation"])

        print("英文接在已有草稿后面")
        relay.act("setDraft", text="前面写好的字")
        reply = transcribe(english, "en-US")
        text = draft()
        check("英文转写成功", reply.get("ok"), json.dumps(reply, ensure_ascii=False))
        check("原来的草稿保留在前面", text.startswith("前面写好的字"), repr(text))
        check("英文结果接在后面", "dictation" in text.lower() and "test" in text.lower(), repr(text))
        codex.settle()
        relay.snap(os.path.join(shots, "01-dictated-draft.png"))

        print("失败的情况：说明原因，草稿不动")
        relay.act("setDraft", text="不要动我")
        for label, path, locale, expected in (
            ("静音", silent, "zh-CN", "没听清"),
            ("文件不存在", os.path.join(root, "missing.aiff"), "zh-CN", "无法识别"),
            ("没有设备端模型的语言", chinese, "xx-YY", "不支持听写"),
        ):
            reply = transcribe(path, locale)
            state = relay.state()
            check(f"{label}：给出界面上的原因", not reply.get("ok") and expected in (reply.get("error") or ""),
                  json.dumps(reply, ensure_ascii=False))
            check(f"{label}：草稿没变", state["draft"] == "不要动我", repr(state["draft"]))
        check("不存在的对话被拒绝",
              not relay.act("transcribeFile", conversationID="00000000-0000-0000-0000-000000000000", path=chinese).get("ok"))

        print("设置 → 语音 → 听写语言")
        relay.act("openSettings", section="voice")
        codex.settle()
        window = next((w for w in relay.windows() if w["title"] == "OMPChat Settings" and w["visible"]), None)
        check("设置窗口打开", window is not None)
        if window:
            relay.snap(os.path.join(shots, "02-dictation-language.png"), window["number"])
        relay.act("closeSettings")
    finally:
        if conversation_id:
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
    parser.add_argument("--shots", default=".artifacts/shots/dictation")
    args = parser.parse_args()
    relay = codex.Relay(args.host, args.port, codex.ompshot.resolve_token(args.token))
    check = codex.Checks()
    try:
        run(relay, args.shots, check)
    except (RuntimeError, urllib.error.URLError, KeyError, StopIteration, IndexError, TypeError,
            subprocess.CalledProcessError) as error:
        check("场景跑完", False, f"{type(error).__name__}: {error}")
    print(f"\n{check.passed} 通过，{len(check.failed)} 失败；截图在 {args.shots}")
    sys.exit(0 if not check.failed else 1)


if __name__ == "__main__":
    main()
