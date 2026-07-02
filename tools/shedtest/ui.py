"""Launch / quit a hermetic ShedDesktop.app for tests, and resolve its
socket path.

Unlike a reuse-the-dev-instance model, the harness ALWAYS owns the app it
drives: it force-quits any running instance and launches a fresh one in
test mode, pointed at the in-process mock server (so no real shed-server is
touched) with a throwaway state dir. `open --env` is how LaunchServices
gets our env into the bundled app.
"""

from __future__ import annotations

import os
import platform
import subprocess
import time
from pathlib import Path

from client import ShedDesktop, ShedError, scaled_timeout

REPO_ROOT = Path(__file__).resolve().parents[2]
APP = REPO_ROOT / "build" / "ShedDesktop.app"
DEFAULTS_SUITE = "ai.stridelabs.ShedDesktop.e2e"


def socket_path() -> Path:
    return Path.home() / "Library/Caches/ShedDesktop/shed-desktop.sock"


def _running() -> bool:
    return subprocess.run(
        ["pgrep", "-x", "ShedDesktop"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def is_alive() -> bool:
    try:
        c = ShedDesktop(socket_path())
        try:
            c.identify()
            return True
        finally:
            c.close()
    except (OSError, ShedError):
        return False


def _wait_gone(timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while _running():
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)
    return True


def quit() -> None:
    """Force-quit any running ShedDesktop (the harness always owns a
    hermetic instance, so a developer's running app would be force-quit —
    that is intended). Only unlink the socket/lock once the process is
    CONFIRMED gone: unlinking out from under a still-live (wedged) process
    frees the path and a fresh launch would create a second instance."""
    if _running():
        try:
            subprocess.run(
                ["osascript", "-e", 'tell application "ShedDesktop" to quit'],
                check=False, timeout=5,
            )
        except subprocess.TimeoutExpired:
            pass
        if not _wait_gone(3.0):
            subprocess.run(["pkill", "-x", "ShedDesktop"], check=False)         # SIGTERM
            if not _wait_gone(3.0):
                subprocess.run(["pkill", "-9", "-x", "ShedDesktop"], check=False)  # SIGKILL
                if not _wait_gone(5.0):
                    raise RuntimeError(
                        "ShedDesktop survived SIGKILL — refusing to unlink its socket/lock "
                        "(would risk a second instance)")
    cache = Path.home() / "Library/Caches/ShedDesktop"
    (cache / "shed-desktop.sock").unlink(missing_ok=True)
    (cache / "shed-desktop.lock").unlink(missing_ok=True)
    # Drop the throwaway preferences suite so a run never leaves dev defaults.
    subprocess.run(["defaults", "delete", DEFAULTS_SUITE],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def launch(*, mock_base_url: str, config_path: Path, state_dir: Path,
           host_agent_socket: str | None = None) -> None:
    if platform.system() != "Darwin":
        raise RuntimeError("ShedDesktop requires macOS")
    if not APP.is_dir():
        subprocess.run(["./scripts/bundle.sh", "debug"], cwd=REPO_ROOT, check=True)
    argv = [
        "open", "--env", "SHED_DESKTOP_TEST_MODE=1",
        "--env", f"SHED_DESKTOP_MOCK_BASE_URL={mock_base_url}",
        "--env", f"SHED_DESKTOP_SHED_CONFIG={config_path}",
        "--env", f"SHED_DESKTOP_STATE_DIR={state_dir}",
    ]
    if host_agent_socket:
        argv += ["--env", f"SHED_DESKTOP_HOST_AGENT_SOCKET={host_agent_socket}"]
    # Throwaway UserDefaults suite so preferences never touch the dev's real
    # defaults (the SHED_DESKTOP_STATE_DIR analog for UserDefaults).
    argv += ["--env", f"SHED_DESKTOP_DEFAULTS_SUITE={DEFAULTS_SUITE}"]
    # The Rust core is the default (M0). Forward SHED_DESKTOP_RUST_CORE verbatim
    # whenever the harness set it, so the `=0` Swift-fallback leg is exercised
    # (and an explicit `=1` still works). Unset ⇒ the app defaults to rust.
    rust_core = os.environ.get("SHED_DESKTOP_RUST_CORE")
    if rust_core is not None:
        argv += ["--env", f"SHED_DESKTOP_RUST_CORE={rust_core}"]
    argv += [str(APP)]
    subprocess.run(argv, check=True)
    wait_alive(mock_base_url=mock_base_url)


def wait_alive(*, mock_base_url: str, timeout: float = 30.0) -> None:
    """Block until the app answers `identify` AND confirms it's hermetic
    (test mode + the expected mock base URL). Failing fast here stops a
    misconfigured run from silently hitting a real server."""
    timeout = scaled_timeout(timeout)
    deadline = time.monotonic() + timeout
    while True:
        try:
            c = ShedDesktop(socket_path())
            try:
                info = c.identify()
                # Confirm the active backend matches the flag so a silent Rust->
                # Swift downgrade can't make a run falsely green. A per-host Rust
                # adapter failure now fails loudly via configError (see
                # ShedServerClient) rather than quietly serving over Swift.
                # Default-on (M0): unset ⇒ rust; only an explicit `=0` selects swift.
                want_core = "swift" if os.environ.get("SHED_DESKTOP_RUST_CORE") == "0" else "rust"
                if (info.get("test_mode")
                        and info.get("mock_base_url") == mock_base_url
                        and info.get("core") == want_core):
                    return
            finally:
                c.close()
        except (OSError, ShedError):
            pass
        if time.monotonic() >= deadline:
            raise TimeoutError(f"ShedDesktop not hermetically ready within {timeout}s")
        time.sleep(0.25)
