#!/usr/bin/env python3
"""Loopback OpenAI-compatible provider used by the Jarvis UI tests.

Run it before the UI test starts:

    python3 Tests/JarvisAcceptanceUITests/mock_provider.py

It answers every request on 127.0.0.1:8765 with the same Markdown answer,
including a ``[channel:N:M]`` marker that the app must keep verbatim.
Requests whose body mentions "long story" wait 8 seconds so a test can
cancel while the answer is still loading. Every request is appended to
/tmp/jarvis_mock.log for debugging.
"""

import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ANSWER = "**HELLO** and `code` — [channel:13:1]"
LOG_PATH = "/tmp/jarvis_mock.log"


class Handler(BaseHTTPRequestHandler):
    def _handle(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        with open(LOG_PATH, "a") as log:
            log.write(
                "{} {} format={} auth={} body={}\n".format(
                    self.command,
                    self.path,
                    self.headers.get("content-type"),
                    bool(self.headers.get("authorization") or self.headers.get("x-api-key")),
                    body[:200].decode("utf-8", "replace"),
                )
            )
        if b"long story" in body:
            time.sleep(8)

        payload = {
            "id": "mock",
            "object": "chat.completion",
            "choices": [
                {"index": 0, "message": {"role": "assistant", "content": ANSWER}}
            ],
        }
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_POST = _handle
    do_GET = _handle

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
