"""A hermetic in-process fake shed-server.

A stdlib ThreadingHTTPServer on 127.0.0.1:<ephemeral> the harness points
the app at (via SHED_DESKTOP_MOCK_BASE_URL in test mode), so E2E runs
without a real shed-server and nothing leaves the box. State is a plain
dict the test mutates directly (server + test share the pytest process),
then forces a poll via `sheds.refresh`.

Covers M0 (info + list) now; the lifecycle + SSE create routes (M1) land
when that phase does.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


DEFAULT_INFO = {
    "name": "mock",
    "version": "0.0.0-mock",
    "ssh_port": 2222,
    "http_port": 8080,
    "backend": "vz",
}

DEFAULT_SHEDS = [
    {
        "name": "hello-world",
        "status": "running",
        "created_at": "2026-05-31T13:33:00.884935839-05:00",
        "container_id": "fc-hello-world",
        "backend": "firecracker",
        "ip_address": "172.30.0.2",
        "cpus": 2,
        "memory_mb": 4096,
        "started_at": "2026-05-31T18:33:02.364547927Z",
    },
    {
        "name": "callbell",
        "status": "stopped",
        "backend": "vz",
        "image": "base",
    },
]


class MockShedServer:
    def __init__(self):
        # The app's background poller reads this state from handler threads
        # concurrently with test setup mutating it, so all access is guarded.
        self._lock = threading.Lock()
        self.info = dict(DEFAULT_INFO)
        # `sheds` may be a list or None (the real server returns
        # `{"sheds": null}` when empty — a decoding path we must exercise).
        self.sheds: list | None = [dict(s) for s in DEFAULT_SHEDS]
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    @property
    def base_url(self) -> str:
        assert self._httpd is not None
        host, port = self._httpd.server_address[0], self._httpd.server_address[1]
        return f"http://{host}:{port}"

    def snapshot(self) -> tuple[dict, list | None]:
        with self._lock:
            return dict(self.info), (None if self.sheds is None else list(self.sheds))

    def set_sheds(self, sheds: list | None) -> None:
        with self._lock:
            self.sheds = sheds

    def reset(self) -> None:
        with self._lock:
            self.info = dict(DEFAULT_INFO)
            self.sheds = [dict(s) for s in DEFAULT_SHEDS]

    def start(self) -> None:
        state = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):  # silence default stderr logging
                pass

            def _send(self, code: int, body: dict):
                payload = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self):
                info, sheds = state.snapshot()
                if self.path == "/api/info":
                    self._send(200, info)
                elif self.path == "/api/sheds":
                    self._send(200, {"sheds": sheds})
                else:
                    self._send(404, {"error": "not found"})

        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None
