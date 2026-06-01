"""An in-process fake shed-host-agent speaking the UDS approval protocol.

Stands in for the real Go host agent so the approval queue, policy engine,
audit store, and merged activity feed can be driven end-to-end without it.
The harness points the app at this socket via SHED_DESKTOP_HOST_AGENT_SOCKET;
the app connects, sends `hello`, and we reply `hello_ack`. Tests then emit
approval_request / event frames and assert on the recorded responses.
"""

from __future__ import annotations

import json
import os
import socket
import tempfile
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class FakeHostAgent:
    def __init__(self):
        self._dir = tempfile.mkdtemp(prefix="fake-host-agent-")
        self.socket_path = os.path.join(self._dir, "host-agent.sock")
        self._srv: socket.socket | None = None
        self._conn: socket.socket | None = None
        self._lock = threading.Lock()
        self._responses: dict[str, dict] = {}
        self._hello_seen = threading.Event()
        self._thread: threading.Thread | None = None
        self._running = False

    # -- lifecycle --------------------------------------------------------
    def start(self) -> None:
        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(self.socket_path)
        self._srv.listen(1)
        self._running = True
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._running = False
        for s in (self._conn, self._srv):
            try:
                if s:
                    s.close()
            except OSError:
                pass

    def _accept_loop(self) -> None:
        while self._running:
            try:
                conn, _ = self._srv.accept()
            except OSError:
                return
            with self._lock:
                self._conn = conn
            threading.Thread(target=self._read_loop, args=(conn,), daemon=True).start()

    def _read_loop(self, conn: socket.socket) -> None:
        buf = b""
        while self._running:
            try:
                chunk = conn.recv(1 << 16)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                self._handle(conn, line)

    def _handle(self, conn: socket.socket, line: bytes) -> None:
        try:
            msg = json.loads(line)
        except ValueError:
            return
        t = msg.get("type")
        if t == "hello":
            ack = {
                "v": 1, "type": "hello_ack", "id": str(uuid.uuid4()), "ts": _now_iso(),
                "agent": {"version": "fake", "approval_method": "shed-desktop"},
                "namespaces": ["ssh-agent", "aws-credentials", "docker-credentials"],
                "gate_namespaces": ["ssh-agent"],
                "request_timeout_ms": 25000, "accepted": True,
            }
            self._send(conn, ack)
            self._hello_seen.set()
        elif t == "approval_response":
            with self._lock:
                self._responses[msg.get("request_id", "")] = msg
        elif t == "pong":
            pass

    def _send(self, conn: socket.socket, obj: dict) -> None:
        try:
            conn.sendall((json.dumps(obj) + "\n").encode())
        except OSError:
            pass

    def _send_active(self, obj: dict) -> None:
        with self._lock:
            conn = self._conn
        if conn:
            self._send(conn, obj)

    # -- test API ---------------------------------------------------------
    def wait_connected(self, timeout: float = 10.0) -> bool:
        return self._hello_seen.wait(timeout)

    def emit_request(self, namespace: str, op: str, shed: str, detail: str = "",
                     expires_in_s: float = 25.0, request_id: str | None = None,
                     server: str = "") -> str:
        rid = request_id or str(uuid.uuid4())
        expires = (datetime.now(timezone.utc) + timedelta(seconds=expires_in_s)).strftime("%Y-%m-%dT%H:%M:%SZ")
        frame = {
            "v": 1, "type": "approval_request", "id": rid, "ts": _now_iso(),
            "namespace": namespace, "op": op, "shed": shed, "detail": detail,
            "expires_at": expires,
        }
        # The real agent omits `server` in single-server mode (#21); mirror that.
        if server:
            frame["server"] = server
        self._send_active(frame)
        return rid

    def emit_event(self, namespace: str, op: str, shed: str, result: str = "ok",
                   detail: str = "", approval: str = "none", server: str = "") -> None:
        frame = {
            "v": 1, "type": "event", "id": str(uuid.uuid4()), "ts": _now_iso(),
            "kind": "audit", "ns": namespace, "op": op, "shed": shed,
            "result": result, "detail": detail, "approval": approval,
        }
        if server:
            frame["server"] = server
        self._send_active(frame)

    def wait_response(self, request_id: str, timeout: float = 10.0) -> dict | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._lock:
                if request_id in self._responses:
                    return self._responses[request_id]
            time.sleep(0.05)
        return None
