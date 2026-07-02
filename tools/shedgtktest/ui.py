"""Launch / quit a hermetic shed-gtk for tests.

The harness OWNS the process: it launches a fresh shed-gtk in test mode, pointed
at an in-process mock (so no real shed-server is touched) with temp HOME +
XDG_RUNTIME_DIR (so it never reads the dev's ~/.shed or binds a real socket) and
a fixture config. stdout/stderr are captured to a log the CI uploads. Mirrors
tools/shedtest, adapted for the GTK binary + its IPC socket. A display is
required to realize the window — the native session on a dev Mac, Xvfb on CI.
"""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

from client import GtkClient, GtkError, scaled_timeout

REPO_ROOT = Path(__file__).resolve().parents[2]
BIN = REPO_ROOT / "core" / "target" / "debug" / "shed-gtk"


def ensure_built() -> None:
    if not BIN.exists():
        raise RuntimeError(
            f"shed-gtk binary not found at {BIN}; build it first "
            "(`make gtk-build`, or `cargo build -p shed-gtk` in core/)."
        )


class GtkApp:
    """A harness-owned shed-gtk instance + its IPC socket."""

    def __init__(self, *, mock_base_url: str, config_path: Path, runtime_dir: Path):
        self.mock_base_url = mock_base_url
        self.runtime_dir = runtime_dir
        # The XDG default socket path with our temp XDG_RUNTIME_DIR.
        self.socket_path = runtime_dir / "shed-gtk" / "shed-gtk.sock"
        # Full env + hermeticity overrides: HOME/XDG_RUNTIME_DIR redirected to the
        # temp dir (never the dev's ~/.shed or real runtime socket), the config
        # pinned to the fixture, test mode + mock set. SHED_GTK_SOCKET is cleared
        # so the XDG default (under runtime_dir) is used.
        env = dict(os.environ)
        env["HOME"] = str(runtime_dir)
        env["XDG_RUNTIME_DIR"] = str(runtime_dir)
        env["SHED_GTK_TEST_MODE"] = "1"
        env["SHED_GTK_MOCK_BASE_URL"] = mock_base_url
        env["SHED_GTK_SHED_CONFIG"] = str(config_path)
        env.pop("SHED_GTK_SOCKET", None)
        self._env = env
        self._log_path = runtime_dir / "shed-gtk.log"
        self._log = None
        self._proc: subprocess.Popen | None = None

    def launch(self) -> None:
        ensure_built()
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        self._log = open(self._log_path, "wb")
        self._proc = subprocess.Popen(
            [str(BIN)], env=self._env, stdout=self._log, stderr=subprocess.STDOUT
        )
        self.wait_alive()

    def wait_alive(self, timeout: float = 30.0) -> None:
        """Block until shed-gtk answers identify AND confirms hermeticity
        (test mode + platform=gtk + core=rust + the expected mock base URL)."""
        deadline = time.monotonic() + scaled_timeout(timeout)
        while True:
            try:
                c = GtkClient(self.socket_path)
                try:
                    info = c.identify()
                    if (
                        info.get("test_mode")
                        and info.get("core") == "rust"
                        and info.get("platform") == "gtk"
                        and info.get("mock_base_url") == self.mock_base_url
                    ):
                        return
                finally:
                    c.close()
            except (OSError, GtkError):
                pass
            if self._proc and self._proc.poll() is not None:
                raise RuntimeError(
                    f"shed-gtk exited early (code {self._proc.returncode}); "
                    f"see {self._log_path}"
                )
            if time.monotonic() >= deadline:
                raise TimeoutError(f"shed-gtk not hermetically ready within {timeout}s")
            time.sleep(0.2)

    def quit(self) -> None:
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        if self._log is not None:
            self._log.close()
