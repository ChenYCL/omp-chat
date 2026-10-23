#!/usr/bin/env python3
"""Local OpenAI-compatible relay for OMP Chat smoke testing."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = {"object": "list", "data": [{"id": "mock-model", "object": "model", "owned_by": "local"}]}
CHUNKS = ["你好", "！我是", "本地", "模拟中继。"]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "OMPMock/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            self._json(MODELS)
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            json.loads(raw)
        except Exception:
            pass
        if not self.path.startswith("/v1/chat/completions"):
            self._json({"error": "not found"}, 404)
            return
        if self.headers.get("Authorization") != "Bearer sk-local-test":
            self._json({"error": {"message": "bad key"}}, 401)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for index, text in enumerate(CHUNKS):
            payload = {"choices": [{"index": 0, "delta": {"content": text}}]}
            self.wfile.write(b"data: " + json.dumps(payload, ensure_ascii=False).encode() + b"\n\n")
            self.wfile.flush()
            time.sleep(0.25)
        final = {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
        usage = {"choices": [], "usage": {"prompt_tokens": 9, "completion_tokens": 7}}
        self.wfile.write(b"data: " + json.dumps(final).encode() + b"\n\n")
        self.wfile.write(b"data: " + json.dumps(usage).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18791
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
