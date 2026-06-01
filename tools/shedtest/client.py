"""Thin JSON-IPC client for a running ShedDesktop app.

Speaks the newline-delimited JSON protocol directly over the Unix socket —
the same contract `shedctl` uses. Tests drive the app through this and read
back via `ui.state` / `sheds.list`, exercising exactly the op set users
drive. No subprocess on the hot path; request ids are string-wrapped int64
on the wire and surfaced as ints here.
"""

from __future__ import annotations

import base64
import json
import os
import socket
import time

# Scale every wait from one knob so a slower CI runner can buy headroom
# without editing each call site. Default 1.0; CI sets the scale higher.
_TIMEOUT_SCALE = float(os.environ.get("SHED_DESKTOP_TEST_TIMEOUT_SCALE", "1.0"))


def scaled_timeout(timeout: float) -> float:
    return timeout * _TIMEOUT_SCALE


class ShedError(Exception):
    """A server error envelope (`ok: false`) or a transport failure."""

    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class Timeout(ShedError):
    def __init__(self, message: str):
        super().__init__("timeout", message)


class ShedDesktop:
    def __init__(self, socket_path: str):
        self.path = str(socket_path)
        self._next_id = 0
        self._buf = b""
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        # A timeout so a wedged app (accepts but never replies) surfaces as a
        # test failure instead of hanging CI forever.
        self._sock.settimeout(scaled_timeout(15.0))
        self._sock.connect(self.path)

    # -- lifecycle --------------------------------------------------------
    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass

    def __enter__(self) -> "ShedDesktop":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    # -- transport --------------------------------------------------------
    def call(self, op: str, params: dict | None = None) -> dict:
        self._next_id += 1
        req = {"id": str(self._next_id), "op": op, "params": params or {}}
        self._sock.sendall((json.dumps(req) + "\n").encode())
        resp = json.loads(self._readline())
        if not resp.get("ok"):
            err = resp.get("error") or {}
            raise ShedError(err.get("code", "unknown"), err.get("message", ""))
        return resp.get("result") or {}

    def _readline(self) -> str:
        while b"\n" not in self._buf:
            try:
                chunk = self._sock.recv(1 << 16)
            except socket.timeout as e:
                raise Timeout("no IPC response within socket timeout") from e
            if not chunk:
                raise ShedError("disconnected", "socket closed mid-response")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\n", 1)
        return line.decode()

    # -- ops --------------------------------------------------------------
    def identify(self) -> dict:
        return self.call("identify")

    def ui_state(self) -> dict:
        return self.call("ui.state")

    def navigate(self, pane: str) -> dict:
        return self.call("ui.navigate", {"pane": pane})

    def show_window(self) -> None:
        self.call("ui.show_window")

    def open_menu(self, open_: bool) -> None:
        self.call("ui.open_menu", {"open": open_})

    def open_preferences(self) -> None:
        self.call("ui.open_preferences")

    def host_list(self) -> list[dict]:
        return self.call("host.list")["hosts"]

    def sheds_list(self, host: str | None = None) -> list[dict]:
        params = {"host": host} if host else {}
        return self.call("sheds.list", params)["sheds"]

    def refresh(self) -> None:
        self.call("sheds.refresh")

    # -- M1: lifecycle, create, terminal ---------------------------------
    def shed_action(self, action: str, name: str, host: str | None = None) -> None:
        params = {"name": name}
        if host:
            params["host"] = host
        self.call(f"shed.{action}", params)

    def create_start(self, name: str, host: str | None = None, **fields) -> str:
        params = {"name": name, **fields}
        if host:
            params["host"] = host
        return self.call("create.start", params)["create_id"]

    def create_status(self, create_id: str) -> dict:
        return self.call("create.status", {"create_id": create_id})

    def terminal_preview(self, shed: str, host: str | None = None, session: str | None = None) -> dict:
        params: dict = {"shed": shed}
        if host:
            params["host"] = host
        if session:
            params["session"] = session
        return self.call("terminal.preview", params)

    # -- M2: remote control ----------------------------------------------
    def rc_classify(self, kind: str, pane: str) -> dict:
        return self.call("rc.classify", {"kind": kind, "pane": pane})

    def rc_list(self, host: str | None = None, shed: str | None = None) -> list[dict]:
        params: dict = {}
        if host:
            params["host"] = host
        if shed:
            params["shed"] = shed
        return self.call("rc.list", params)["sessions"]

    def rc_launch(self, shed: str, kind: str = "repl", host: str | None = None,
                  display_name: str | None = None) -> dict:
        params: dict = {"shed": shed, "kind": kind}
        if host:
            params["host"] = host
        if display_name:
            params["display_name"] = display_name
        return self.call("rc.launch", params)

    def rc_kill(self, shed: str, slug: str, host: str | None = None) -> None:
        params: dict = {"shed": shed, "slug": slug}
        if host:
            params["host"] = host
        self.call("rc.kill", params)

    # -- M3: approvals + activity ----------------------------------------
    def approvals_list(self) -> list[dict]:
        return self.call("approvals.list")["approvals"]

    def approval_decide(self, id: str, decision: str, grant_session: bool = False, always: bool = False) -> None:
        self.call("approval.decide",
                  {"id": id, "decision": decision, "grant_session": grant_session, "always": always})

    def activity_list(self, limit: int = 200) -> list[dict]:
        return self.call("activity.list", {"limit": limit})["entries"]

    def activity_log_path(self) -> str:
        return self.call("activity.log_path")["path"]

    def policy_set(self, rules: list[dict]) -> None:
        self.call("policy.set", {"rules": rules})

    def policy_list(self) -> list[dict]:
        return self.call("policy.list")["rules"]

    # -- M5: notifications (fake presenter in test mode) ------------------
    def notifications_list(self) -> list[dict]:
        return self.call("notifications.list")["notifications"]

    def notification_invoke(self, id: str, action: str) -> None:
        self.call("notification.invoke", {"id": id, "action": action})

    def window_metrics(self) -> dict:
        return self.call("app.window_metrics")

    def screenshot(self, surface: str = "window", scale: int = 1) -> tuple[bytes, int, int]:
        r = self.call("app.screenshot", {"surface": surface, "scale": scale})
        return base64.b64decode(r["png"]), r["width"], r["height"]

    # -- waits (poll the op set; no sleeps in tests) ----------------------
    def wait_until(self, pred, timeout: float = 5.0, what: str = "condition") -> None:
        eff = scaled_timeout(timeout)
        deadline = time.monotonic() + eff
        while True:
            try:
                if pred():
                    return
            except ShedError:
                pass
            if time.monotonic() >= deadline:
                raise Timeout(f"timed out after {eff}s waiting for {what}")
            time.sleep(0.1)

    def shed_status(self, name: str) -> str | None:
        for s in self.sheds_list():
            if s["name"] == name:
                return s["status"]
        return None
