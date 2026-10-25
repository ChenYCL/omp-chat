#!/usr/bin/env python3
"""Relay Hub — 跨网络中继（参考实现，零依赖，Python 3.12 标准库）。

拓扑见 docs/relay-hub.md：Mac 与 iPhone 都主动连本服务，用房间码找到彼此，
本服务只做纯转发，不持久化会话内容。

    python3 tools/relay-hub/relay_hub.py --port 8899

生产部署请在前面加 Caddy/Nginx 终结 TLS，只暴露 443。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import secrets
import time
from dataclasses import dataclass, field
from typing import Any

ROOM_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
ROOM_LENGTH = 6
ROOM_TTL_SECONDS = 600
MAX_ROOM_CODE_ATTEMPTS_PER_MINUTE = 5
MAX_COMMAND_LOG = 200
PING_INTERVAL = 15.0


def new_room_code() -> str:
    return "".join(secrets.choice(ROOM_ALPHABET) for _ in range(ROOM_LENGTH))


def normalize_room(raw: str | None) -> str | None:
    if not raw:
        return None
    code = raw.strip().upper()
    if len(code) != ROOM_LENGTH or any(ch not in ROOM_ALPHABET for ch in code):
        return None
    return code


@dataclass
class Room:
    code: str
    snapshot: dict[str, Any] | None = None
    rev: int = 0
    host_writer: asyncio.StreamWriter | None = None
    client_writers: set[asyncio.StreamWriter] = field(default_factory=set)
    commands: list[dict[str, Any]] = field(default_factory=list)
    host_offline_since: float | None = field(default=None)

    def host_online(self) -> bool:
        return self.host_writer is not None


class Hub:
    def __init__(self) -> None:
        self.rooms: dict[str, Room] = {}
        self.failed_pairings: dict[str, list[float]] = {}

    # MARK: - Rooms

    def room(self, code: str) -> Room:
        room = self.rooms.get(code)
        if room is None:
            room = Room(code=code)
            self.rooms[code] = room
        return room

    def note_failure(self, ip: str) -> bool:
        """记录一次失败配对；返回 True 表示应限速。"""
        now = time.time()
        attempts = [t for t in self.failed_pairings.get(ip, []) if now - t < 60]
        attempts.append(now)
        self.failed_pairings[ip] = attempts
        return len(attempts) > MAX_ROOM_CODE_ATTEMPTS_PER_MINUTE

    def reap(self) -> None:
        now = time.time()
        for code, room in list(self.rooms.items()):
            if room.host_online():
                room.host_offline_since = None
                continue
            if room.host_offline_since is None:
                room.host_offline_since = now
            elif now - room.host_offline_since > ROOM_TTL_SECONDS:
                del self.rooms[code]

    # MARK: - Publish

    def publish(self, room: Room, snapshot: dict[str, Any]) -> int:
        room.rev += 1
        snapshot = dict(snapshot)
        snapshot["rev"] = room.rev
        room.snapshot = snapshot
        payload = f'event: rev\ndata: {{"rev":{room.rev}}}\n\n'.encode()
        for writer in list(room.client_writers):
            writer.write(payload)
        return room.rev


HUB = Hub()


# MARK: - HTTP plumbing


async def read_request(reader: asyncio.StreamReader) -> tuple[str, str, dict[str, str], bytes] | None:
    try:
        line = await reader.readline()
    except (ConnectionResetError, asyncio.IncompleteReadError):
        return None
    if not line:
        return None
    parts = line.decode("latin-1").strip().split(" ")
    if len(parts) < 2:
        return None
    method, target = parts[0], parts[1]

    headers: dict[str, str] = {}
    while True:
        raw = await reader.readline()
        if raw in (b"\r\n", b"\n", b""):
            break
        key, _, value = raw.decode("latin-1").partition(":")
        headers[key.strip().lower()] = value.strip()

    length = int(headers.get("content-length", "0") or 0)
    body = await reader.readexactly(length) if length > 0 else b""
    return method, target, headers, body


def response(status: str, payload: dict[str, Any] | list[Any] | None = None) -> bytes:
    if payload is None:
        body = b""
        content_type = "text/plain"
    else:
        body = json.dumps(payload, ensure_ascii=False).encode()
        content_type = "application/json"
    head = (
        f"HTTP/1.1 {status}\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: keep-alive\r\n\r\n"
    ).encode()
    return head + body


SSE_HEAD = (
    b"HTTP/1.1 200 OK\r\n"
    b"Content-Type: text/event-stream\r\n"
    b"Cache-Control: no-cache\r\n"
    b"Connection: keep-alive\r\n\r\n"
)


def split_target(target: str) -> tuple[str, dict[str, str]]:
    path, _, query = target.partition("?")
    params: dict[str, str] = {}
    if query:
        for pair in query.split("&"):
            key, _, value = pair.partition("=")
            params[key] = value
    return path, params


async def keep_alive_sse(writer: asyncio.StreamWriter, room: Room) -> None:
    try:
        while True:
            await asyncio.sleep(PING_INTERVAL)
            writer.write(b": ping\n\n")
            await writer.drain()
    except (ConnectionResetError, asyncio.CancelledError):
        return


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    peer = writer.get_extra_info("peername")
    ip = peer[0] if peer else "unknown"
    request = await read_request(reader)
    if request is None:
        writer.close()
        return
    method, target, _headers, body = request
    path, params = split_target(target)
    # Health is room-less so operators can probe the hub itself.
    if path == "/v1/health":
        writer.write(response("200 OK", {"ok": True, "rooms": len(HUB.rooms)}))
        await writer.drain()
        writer.close()
        return

    room_code = normalize_room(params.get("room"))

    if room_code is None:
        writer.write(response("400 Bad Request", {"error": "invalid room"}))
        await writer.drain()
        writer.close()
        return

    # Reject room probing: an unknown room on the client side is a failed pairing.
    is_client_route = path.startswith("/v1/client/")
    if is_client_route and room_code not in HUB.rooms:
        if HUB.note_failure(ip):
            writer.write(response("429 Too Many Requests", {"error": "too many attempts"}))
            await writer.drain()
            writer.close()
            return

    room = HUB.room(room_code)

    try:
        # MARK: Host state ingest
        if method == "POST" and path == "/v1/host/state":
            if not room.host_online():
                writer.write(response("409 Conflict", {"error": "host offline"}))
                await writer.drain()
                writer.close()
                return
            try:
                snapshot = json.loads(body.decode() or "{}")
            except json.JSONDecodeError:
                writer.write(response("400 Bad Request", {"error": "bad json"}))
                await writer.drain()
                writer.close()
                return
            rev = HUB.publish(room, snapshot)
            writer.write(response("200 OK", {"ok": True, "rev": rev}))
            await writer.drain()
            writer.close()
            return

        # MARK: Host command stream
        if method == "GET" and path == "/v1/host/stream":
            writer.write(SSE_HEAD)
            writer.write(b'event: hello\ndata: {"role":"host"}\n\n')
            await writer.drain()
            room.host_writer = writer
            room.host_offline_since = None
            ping = asyncio.create_task(keep_alive_sse(writer, room))
            try:
                while True:
                    raw = await reader.readline()
                    if not raw:
                        break
            except ConnectionResetError:
                pass
            finally:
                ping.cancel()
                if room.host_writer is writer:
                    room.host_writer = None
                    room.host_offline_since = time.time()
                writer.close()
            return

        # MARK: Client state stream
        if method == "GET" and path == "/v1/client/stream":
            writer.write(SSE_HEAD)
            hello = {
                "rev": room.rev,
                "host": (room.snapshot or {}).get("host", ""),
            }
            writer.write(f"event: hello\ndata: {json.dumps(hello)}\n\n".encode())
            await writer.drain()
            room.client_writers.add(writer)
            ping = asyncio.create_task(keep_alive_sse(writer, room))
            try:
                while True:
                    raw = await reader.readline()
                    if not raw:
                        break
            except ConnectionResetError:
                pass
            finally:
                ping.cancel()
                room.client_writers.discard(writer)
                writer.close()
            return

        # MARK: Client full state
        if method == "GET" and path == "/v1/client/state":
            if room.snapshot is None:
                writer.write(response("404 Not Found", {"error": "no state"}))
            else:
                writer.write(response("200 OK", room.snapshot))
            await writer.drain()
            writer.close()
            return

        # MARK: Client command
        if method == "POST" and path == "/v1/client/command":
            host = room.host_writer
            if host is None:
                writer.write(response("409 Conflict", {"error": "host offline"}))
                await writer.drain()
                writer.close()
                return
            try:
                command = json.loads(body.decode() or "{}")
            except json.JSONDecodeError:
                writer.write(response("400 Bad Request", {"error": "bad json"}))
                await writer.drain()
                writer.close()
                return
            allowed = {
                "input", "stop", "select", "newConversation", "rename", "delete",
                "regenerate", "deleteMessage", "editAndResend", "branch",
                "feedback", "setModel", "togglePin", "toggleArchive",
                "toggleLock", "setUnread",
            }
            if command.get("kind") not in allowed:
                writer.write(response("400 Bad Request", {"error": "bad kind"}))
                await writer.drain()
                writer.close()
                return
            room.commands.append(command)
            if len(room.commands) > MAX_COMMAND_LOG:
                room.commands = room.commands[-MAX_COMMAND_LOG:]
            host.write(f"event: command\ndata: {json.dumps(command, ensure_ascii=False)}\n\n".encode())
            try:
                await host.drain()
            except ConnectionResetError:
                room.host_writer = None
                writer.write(response("409 Conflict", {"error": "host gone"}))
                await writer.drain()
                writer.close()
                return
            writer.write(response("200 OK", {"ok": True}))
            await writer.drain()
            writer.close()
            return

        # MARK: Health / info
        if method == "GET" and path == "/v1/health":
            writer.write(response("200 OK", {"ok": True, "rooms": len(HUB.rooms)}))
            await writer.drain()
            writer.close()
            return

        writer.write(response("404 Not Found", {"error": "no route"}))
        await writer.drain()
        writer.close()
    except (ConnectionResetError, BrokenPipeError):
        writer.close()


async def reaper() -> None:
    while True:
        await asyncio.sleep(60)
        HUB.reap()


async def main() -> None:
    parser = argparse.ArgumentParser(description="OMPChat Relay Hub")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--print-room", action="store_true", help="打印一个可用房间码")
    args = parser.parse_args()

    if args.print_room:
        print(new_room_code())
        return

    server = await asyncio.start_server(handle, args.host, args.port)
    asyncio.create_task(reaper())
    print(f"relay hub listening on {args.host}:{args.port}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
