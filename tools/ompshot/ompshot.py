#!/usr/bin/env python3
"""ompshot: screenshots of OMPChat's own windows without bringing it to the front.

The app renders its windows itself (GET /debug/snapshot on its relay), so the
capture works while OMPChat is behind other windows, never contains another
app, and needs no Screen Recording permission.

    ompshot.py windows                 list OMPChat's windows
    ompshot.py snap                    PNG of the main window
    ompshot.py snap -w 36245 -o a.png  PNG of one window, to a chosen path

Needs 设置 → 远程控制 enabled in OMPChat. The token comes from --token, then
$OMP_RELAY_TOKEN, then the app's own secrets file; it is never printed.
"""

import argparse
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request

CONTAINER_STORE = os.path.expanduser(
    "~/Library/Containers/com.ace.ompchat/Data/Library/Application Support/OMPChat"
)
TOKEN_ACCOUNT = "relay-host.token"


def resolve_token(explicit):
    if explicit:
        return explicit
    env = os.environ.get("OMP_RELAY_TOKEN")
    if env:
        return env
    store = os.environ.get("OMPCHAT_STORE_DIR") or CONTAINER_STORE
    path = os.path.join(store, "secrets.json")
    try:
        with open(path, encoding="utf-8") as handle:
            token = json.load(handle).get("secrets", {}).get(TOKEN_ACCOUNT)
    except (OSError, ValueError):
        token = None
    if not token:
        sys.exit(f"找不到配对令牌：用 --token 或 OMP_RELAY_TOKEN 传入（也没在 {path} 里找到）")
    return token


def request(args, path):
    url = f"http://{args.host}:{args.port}{path}"
    req = urllib.request.Request(url, headers={"X-OMP-Token": resolve_token(args.token)})
    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as response:
            return response.read(), response.headers.get("Content-Type", "")
    except urllib.error.HTTPError as error:
        reasons = {
            400: "window 参数必须是窗口编号（数字）",
            401: "令牌不对",
            404: "没有这个窗口，先用 windows 看编号",
            503: "这个 OMPChat 版本没有截图接口，装上新版本再试",
        }
        sys.exit(f"HTTP {error.code}：{reasons.get(error.code, error.reason)}")
    except urllib.error.URLError as error:
        sys.exit(f"连不上 {args.host}:{args.port}（{error.reason}）：OMPChat 没开，或 设置 → 远程控制 没打开")


def png_size(data):
    """Width and height from the PNG IHDR chunk, or None when it is not a PNG."""
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", data[16:24])


def cmd_windows(args):
    body, _ = request(args, "/debug/windows")
    windows = json.loads(body).get("windows", [])
    if not windows:
        print("没有窗口")
        return
    for w in windows:
        flags = " ".join(f for f, on in (("main", w.get("main")), ("key", w.get("key")),
                                         ("hidden", not w.get("visible"))) if on)
        print(f"{w['number']:>8}  {w['kind']:<8} {w['width']:>5}x{w['height']:<5} {flags:<12} {w['title']}")


def cmd_snap(args):
    path = "/debug/snapshot" + (f"?window={args.window}" if args.window is not None else "")
    body, content_type = request(args, path)
    size = png_size(body)
    if not content_type.startswith("image/png") or size is None:
        sys.exit(f"返回的不是 PNG（{content_type}）")
    out = args.output or time.strftime("ompshot-%Y%m%d-%H%M%S.png")
    directory = os.path.dirname(out)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(out, "wb") as handle:
        handle.write(body)
    print(f"{out}  {size[0]}x{size[1]}  {len(body)} bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8795)
    parser.add_argument("--token", help="配对令牌；缺省读 $OMP_RELAY_TOKEN 或应用自己的 secrets.json")
    parser.add_argument("--timeout", type=float, default=15)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("windows", help="列出 OMPChat 的窗口").set_defaults(run=cmd_windows)
    snap = sub.add_parser("snap", help="截一个窗口")
    snap.add_argument("-w", "--window", type=int, help="窗口编号；缺省为主窗口")
    snap.add_argument("-o", "--output", help="输出路径；缺省 ompshot-<时间>.png")
    snap.set_defaults(run=cmd_snap)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
