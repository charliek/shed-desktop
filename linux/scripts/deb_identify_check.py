"""Post-install check for the shed-gtk .deb: launch the installed binary under a
virtual display and assert it answers `identify` (proving the runtime deps are
satisfied, the window realizes, and the IPC socket binds). Run inside a clean
container after `apt-get install ./shed-gtk_*.deb xvfb`. No mock needed —
identify is backend-independent (test mode without a mock builds no clients)."""

import json
import os
import socket
import subprocess
import sys
import time

SOCK = "/tmp/shed-gtk-debcheck.sock"


def main() -> int:
    env = dict(
        os.environ,
        SHED_GTK_TEST_MODE="1",
        SHED_GTK_SOCKET=SOCK,
        XDG_RUNTIME_DIR="/tmp",
        GDK_BACKEND="x11",
        GSK_RENDERER="cairo",
    )
    proc = subprocess.Popen(["xvfb-run", "-a", "shed-gtk"], env=env)
    try:
        deadline = time.time() + 30
        while time.time() < deadline:
            if proc.poll() is not None:
                print(f"FAIL: shed-gtk exited early ({proc.returncode})", file=sys.stderr)
                return 1
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(10)
                s.connect(SOCK)
                s.sendall(b'{"id":"1","op":"identify","params":{}}\n')
                buf = b""
                while b"\n" not in buf:
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
                s.close()
                r = json.loads(buf.split(b"\n")[0])
                assert r["ok"], r
                info = r["result"]
                assert info["platform"] == "gtk" and info["core"] == "rust", info
                print(f"DEB IDENTIFY OK: platform={info['platform']} core={info['core']}")
                return 0
            except OSError:
                time.sleep(0.5)
        print("FAIL: shed-gtk never answered identify", file=sys.stderr)
        return 1
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
