"""Launch / quit a hermetic shed-desktop UI for tests, and resolve its socket.

Both UIs speak the same IPC, so the test driver is one client parameterized by
`--target`; only launch/quit/socket differ per UI (the Swift `ShedDesktop.app`
vs the `shed-gtk` `shed-desktop` binary). The harness ALWAYS owns the app it
drives: it launches a fresh instance in test mode, pointed at the in-process
mock server (so no real shed-server is touched) with a throwaway state dir.

  - mac: `open --env` injects SHED_DESKTOP_* into the bundled app (LaunchServices
    otherwise drops the caller's env); quit force-quits + clears the throwaway
    UserDefaults suite and socket/lock.
  - gtk: a subprocess with SHED_GTK_* env + a temp HOME/XDG_RUNTIME_DIR (so it
    never reads the dev's ~/.shed or binds a real socket); quit terminates the
    child and removes the temp dir. A display is required to realize the window —
    the native session on a dev Mac, Xvfb on CI.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from client import GtkClient, IPCClient, ShedDesktop, ShedError, scaled_timeout

REPO_ROOT = Path(__file__).resolve().parents[2]
TARGETS = ("mac", "gtk")

# mac: the ad-hoc-signed bundle the harness drives.
APP = REPO_ROOT / "build" / "ShedDesktop.app"
DEFAULTS_SUITE = "ai.stridelabs.ShedDesktop.e2e"

# gtk: the shed-gtk binary (its `[[bin]]` name is `shed-desktop`).
BIN = REPO_ROOT / "core" / "target" / "debug" / "shed-desktop"

# A harness-launched shed-gtk's process + captured log + the temp dir serving as
# its HOME/XDG_RUNTIME_DIR + its launch env. Retained so `wait_alive` can tell a
# crashed-on-boot UI from a slow one, `quit` can terminate + clean up, and the
# second-instance test can spawn a sibling with the same env. `None` until a gtk
# launch; the mac path launches via `open` (no captured child) and leaves unset.
_GTK_PROC: "subprocess.Popen[bytes] | None" = None
_GTK_LOG: Path | None = None
_GTK_LOG_FH = None
_GTK_RUNTIME_DIR: Path | None = None
_GTK_ENV: dict[str, str] | None = None


def socket_path(target: str = "mac") -> Path:
    if target == "mac":
        return Path.home() / "Library/Caches/ShedDesktop/shed-desktop.sock"
    if target == "gtk":
        runtime = _GTK_RUNTIME_DIR or Path(
            os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/shed-gtk-{os.getuid()}"
        )
        return runtime / "shed-gtk" / "shed-gtk.sock"
    raise ValueError(f"unknown target {target!r} (want mac|gtk)")


def _client(target: str) -> IPCClient:
    return ShedDesktop(socket_path(target)) if target == "mac" else GtkClient(socket_path(target))


def gtk_launch_env() -> dict[str, str]:
    """The env the session's shed-gtk was launched with — so the second-instance
    (single-instance flock) test can spawn a sibling against the same runtime."""
    if _GTK_ENV is None:
        raise RuntimeError("no shed-gtk launched this session")
    return dict(_GTK_ENV)


def _gtk_log_path() -> Path:
    """Where a harness-launched shed-gtk's stdout+stderr are captured. Kept
    OUTSIDE the throwaway runtime dir (which `quit` removes) so a boot-failure
    log survives for CI to collect on failure. Honors `SHED_GTK_E2E_LOG_DIR`;
    falls back to the system temp dir."""
    base = Path(os.environ.get("SHED_GTK_E2E_LOG_DIR") or tempfile.gettempdir())
    base.mkdir(parents=True, exist_ok=True)
    return base / "shed-gtk-ui.log"


# -- mac process helpers (unchanged behavior) ----------------------------------
def _running() -> bool:
    return subprocess.run(
        ["pgrep", "-x", "ShedDesktop"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def is_alive(target: str = "mac") -> bool:
    try:
        c = _client(target)
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


def quit(target: str = "mac") -> None:
    """Quit the harness-owned UI. A switch, never flattened: the mac path
    (osascript → pkill → `defaults delete` → unlink sock/lock) and the gtk path
    (terminate/kill the child → remove its temp dir) share nothing."""
    if target == "mac":
        _quit_mac()
    elif target == "gtk":
        _quit_gtk()
    else:
        raise ValueError(f"unknown target {target!r} (want mac|gtk)")


def _quit_mac() -> None:
    """Force-quit any running ShedDesktop (the harness always owns a hermetic
    instance, so a developer's running app would be force-quit — that is
    intended). Only unlink the socket/lock once the process is CONFIRMED gone:
    unlinking out from under a still-live (wedged) process frees the path and a
    fresh launch would create a second instance."""
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


def _quit_gtk() -> None:
    global _GTK_PROC, _GTK_LOG, _GTK_LOG_FH, _GTK_RUNTIME_DIR, _GTK_ENV
    if _GTK_PROC is not None and _GTK_PROC.poll() is None:
        _GTK_PROC.terminate()
        try:
            _GTK_PROC.wait(timeout=scaled_timeout(5))
        except subprocess.TimeoutExpired:
            _GTK_PROC.kill()
    if _GTK_LOG_FH is not None:
        _GTK_LOG_FH.close()
    if _GTK_RUNTIME_DIR is not None:
        shutil.rmtree(_GTK_RUNTIME_DIR, ignore_errors=True)
    _GTK_PROC = None
    _GTK_LOG = None
    _GTK_LOG_FH = None
    _GTK_RUNTIME_DIR = None
    _GTK_ENV = None


def launch(target: str = "mac", *, mock_base_url: str, config_path: Path, state_dir: Path,
           host_agent_socket: str | None = None) -> None:
    """Launch the UI hermetically and block until it answers `identify`.

    `state_dir` is the throwaway per-session dir: on mac SHED_DESKTOP_STATE_DIR;
    on gtk it doubles as HOME + XDG_RUNTIME_DIR (so ~/.shed and the runtime
    socket are both isolated). `host_agent_socket` is mac-only.
    """
    if target == "mac":
        _launch_mac(mock_base_url=mock_base_url, config_path=config_path,
                    state_dir=state_dir, host_agent_socket=host_agent_socket)
    elif target == "gtk":
        _launch_gtk(mock_base_url=mock_base_url, config_path=config_path, runtime_dir=state_dir)
    else:
        raise ValueError(f"unknown target {target!r} (want mac|gtk)")


def _launch_mac(*, mock_base_url: str, config_path: Path, state_dir: Path,
                host_agent_socket: str | None) -> None:
    if platform.system() != "Darwin":
        raise RuntimeError("the mac target requires macOS")
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
    wait_alive("mac", mock_base_url=mock_base_url)


def _launch_gtk(*, mock_base_url: str, config_path: Path, runtime_dir: Path) -> None:
    if not BIN.exists():
        raise RuntimeError(
            f"shed-gtk binary not found at {BIN}; build it first "
            "(`make gtk-build`, or `cargo build -p shed-gtk` in core/).")
    global _GTK_PROC, _GTK_LOG, _GTK_LOG_FH, _GTK_RUNTIME_DIR, _GTK_ENV
    # HOME/XDG_RUNTIME_DIR redirected to the temp dir (never the dev's ~/.shed or
    # real runtime socket), config pinned to the fixture, test mode + mock set.
    # SHED_GTK_SOCKET is cleared so the XDG default (under runtime_dir) is used.
    env = dict(os.environ)
    env["HOME"] = str(runtime_dir)
    env["XDG_RUNTIME_DIR"] = str(runtime_dir)
    env["SHED_GTK_TEST_MODE"] = "1"
    env["SHED_GTK_MOCK_BASE_URL"] = mock_base_url
    env["SHED_GTK_SHED_CONFIG"] = str(config_path)
    env.pop("SHED_GTK_SOCKET", None)
    _GTK_ENV = env
    _GTK_RUNTIME_DIR = runtime_dir
    sock = socket_path("gtk")
    sock.parent.mkdir(parents=True, exist_ok=True)
    _GTK_LOG = _gtk_log_path()
    _GTK_LOG_FH = open(_GTK_LOG, "wb")
    _GTK_PROC = subprocess.Popen(
        [str(BIN)], env=env, stdout=_GTK_LOG_FH, stderr=subprocess.STDOUT)
    wait_alive("gtk", mock_base_url=mock_base_url)


def wait_alive(target: str = "mac", *, mock_base_url: str, timeout: float = 30.0) -> None:
    """Block until the app answers `identify` AND confirms it's hermetic (test
    mode + the expected mock base URL + the target's backend). Failing fast here
    stops a misconfigured run from silently hitting a real server."""
    timeout = scaled_timeout(timeout)
    deadline = time.monotonic() + timeout
    while True:
        try:
            c = _client(target)
            try:
                info = c.identify()
                if _hermetic(target, info, mock_base_url):
                    return
            finally:
                c.close()
        except (OSError, ShedError):
            pass
        # A crashed-on-boot gtk child (already exited) is a hard failure, not a
        # slow boot — surface it (with the captured log) rather than time out.
        if target == "gtk" and _GTK_PROC is not None and _GTK_PROC.poll() is not None:
            raise RuntimeError(
                f"shed-gtk exited early (code {_GTK_PROC.returncode}); see {_GTK_LOG}")
        if time.monotonic() >= deadline:
            raise TimeoutError(f"{target} UI not hermetically ready within {timeout}s")
        time.sleep(0.25)


def _hermetic(target: str, info: dict, mock_base_url: str) -> bool:
    if not (info.get("test_mode") and info.get("mock_base_url") == mock_base_url):
        return False
    if target == "gtk":
        return info.get("core") == "rust" and info.get("platform") == "gtk"
    # mac: confirm the active backend matches the flag so a silent Rust->Swift
    # downgrade can't make a run falsely green. Default-on (M0): unset ⇒ rust;
    # only an explicit `=0` selects swift.
    want_core = "swift" if os.environ.get("SHED_DESKTOP_RUST_CORE") == "0" else "rust"
    return info.get("core") == want_core
