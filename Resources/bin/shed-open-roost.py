#!/usr/bin/env python3
"""Open a new Roost tab running the given command, in a project named after the shed.

Usage: shed-open-roost.py <shed> <cmd>

Speaks Roost's newline-delimited JSON IPC over its Unix socket (see roost
docs/reference/ipc.md). Uses `tab.open` with an explicit argv so the command
runs natively; Roost closes the tab when the process exits (hold=false is
automatic). Note: when the shed project's only tab exits, Roost cascades and
closes the project too.

Stdlib only — no third-party deps.
"""
import json
import os
import socket
import subprocess
import sys
import time

SOCKET_PATH = os.path.expanduser("~/Library/Caches/Roost/roost.sock")
ROOST_BUNDLE_ID = "ai.stridelabs.Roost"


def ensure_running():
    """Launch Roost if its IPC socket isn't present yet, then wait for it."""
    if os.path.exists(SOCKET_PATH):
        return
    subprocess.run(["/usr/bin/open", "-b", ROOST_BUNDLE_ID], check=False)
    for _ in range(100):  # up to ~10s
        if os.path.exists(SOCKET_PATH):
            return
        time.sleep(0.1)


class RoostIPC:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buf = b""
        self._id = 0

    def call(self, op, params):
        self._id += 1
        req = json.dumps({"id": str(self._id), "op": op, "params": params}) + "\n"
        self.sock.sendall(req.encode("utf-8"))
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("roost IPC closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        resp = json.loads(line)
        if not resp.get("ok", False):
            err = resp.get("error", {})
            raise RuntimeError(
                "roost %s failed: %s %s" % (op, err.get("code"), err.get("message"))
            )
        return resp.get("result", {})


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: shed-open-roost.py <shed> <cmd>\n")
        return 2
    shed, cmd = sys.argv[1], sys.argv[2]

    ensure_running()
    if not os.path.exists(SOCKET_PATH):
        sys.stderr.write("roost socket not found (is Roost installed/running?)\n")
        return 1

    ipc = RoostIPC(SOCKET_PATH)

    # Find a project named after the shed, else create one. Project ids are
    # string-wrapped int64s on the wire; pass them back verbatim.
    project_id = None
    listing = ipc.call("tab.list", {})
    for project in listing.get("projects", []):
        if project.get("name") == shed:
            project_id = project.get("id")
            break
    if project_id is None:
        created = ipc.call("project.create", {"name": shed, "cwd": ""})
        project_id = created["project"]["id"]

    # Open a tab running the command. `/bin/sh -lc <cmd>` so the shell-quoted
    # line is word-split safely. Roost auto-closes the tab on process exit.
    ipc.call(
        "tab.open",
        {
            "project_id": project_id,
            "cwd": "",
            "argv": ["/bin/sh", "-lc", cmd],
            "cols": 120,
            "rows": 30,
            "title": shed,
        },
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
