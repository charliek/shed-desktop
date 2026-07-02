"""Newline-JSON IPC client for a running shed-gtk — the same wire the Mac app
speaks ({id, op, params} -> {ok, result|error}). The GTK app exposes a small op
set (identify / sheds.list / dashboard.dump / app.screenshot)."""

from __future__ import annotations

import base64
import json
import os
import socket
import time

# Scale every wait from one knob so a slower CI runner buys headroom without
# editing each call site (mirrors the Mac harness's SHED_DESKTOP_TEST_TIMEOUT_SCALE).
_TIMEOUT_SCALE = float(os.environ.get("SHED_GTK_TEST_TIMEOUT_SCALE", "1.0"))


def scaled_timeout(timeout: float) -> float:
    return timeout * _TIMEOUT_SCALE


class GtkError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class GtkClient:
    def __init__(self, socket_path):
        self.path = str(socket_path)
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.settimeout(15.0)
        self._sock.connect(self.path)
        self._buf = b""
        self._id = 0

    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass

    def __enter__(self) -> "GtkClient":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    def call(self, op: str, params: dict | None = None) -> dict:
        self._id += 1
        req = {"id": str(self._id), "op": op, "params": params or {}}
        self._sock.sendall((json.dumps(req) + "\n").encode())
        resp = json.loads(self._readline())
        if not resp.get("ok"):
            e = resp.get("error") or {}
            raise GtkError(e.get("code", "unknown"), e.get("message", ""))
        return resp.get("result") or {}

    def _readline(self) -> str:
        while b"\n" not in self._buf:
            chunk = self._sock.recv(1 << 16)
            if not chunk:
                raise GtkError("disconnected", "socket closed mid-response")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\n", 1)
        return line.decode()

    # -- ops --------------------------------------------------------------
    def identify(self) -> dict:
        return self.call("identify")

    def sheds_list(self) -> list[dict]:
        return self.call("sheds.list")["sheds"]

    def dashboard_dump(self) -> list[dict]:
        """The sheds the UI currently shows (its rendered state) — the truth op."""
        return self.call("dashboard.dump")["rows"]

    def screenshot(self, scale: int = 1) -> tuple[bytes, int, int]:
        r = self.call("app.screenshot", {"scale": scale})
        return base64.b64decode(r["png"]), r["width"], r["height"]

    def wait_until(self, pred, timeout: float = 10.0, what: str = "condition") -> None:
        eff = scaled_timeout(timeout)
        deadline = time.monotonic() + eff
        while True:
            try:
                if pred():
                    return
            except GtkError:
                pass
            if time.monotonic() >= deadline:
                raise TimeoutError(f"timed out after {eff}s waiting for {what}")
            time.sleep(0.1)
