"""pytest fixtures for the shed-desktop E2E suite (macOS app, shed-gtk, Tauri).

Parameterized by `--target mac|gtk|tauri` (default `$SHED_TEST_TARGET`, else
`mac`). A session fixture starts the shared in-process mock shed-server, then
launches a hermetic UI for the chosen target and drives it over its IPC socket.
The mac target adds a fake host-agent (backing the approval gate) + a per-test
policy reset; the subprocess targets (gtk, tauri) run their binary with a
throwaway HOME/XDG_RUNTIME_DIR — the mac fake-host-agent + policy machinery has
no gtk/tauri analog and is not started there.

Shared tests take the `client` (target-appropriate) + `target` fixtures; the
mac-only suites gate on `SHED_TEST_TARGET`, and the backend-dependent shared
tests carry `@needs_backend` (skipped on tauri until A1b — see `_marks.py`).
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

import ui
from client import GtkClient, ShedDesktop, TauriClient
from mockserver import MockShedServer

# Targets whose UI implements the credential-approval spine (mac + tauri; gtk's
# pane is deferred). Kept in sync with `_marks._APPROVAL_TARGETS`, but defined
# here as a plain constant — importing `_marks` at conftest load (before
# `pytest_configure` sets $SHED_TEST_TARGET) would freeze its markers at the
# wrong target.
_APPROVAL_TARGETS = {"mac", "tauri"}

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fake-host-agent"))
from fake_host_agent import FakeHostAgent  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"
CONFIG = FIXTURES / "config.yaml"


def pytest_addoption(parser):
    parser.addoption(
        "--target", action="store", default=None, choices=list(ui.TARGETS),
        help="which UI to drive (mac|gtk|tauri); default $SHED_TEST_TARGET or mac",
    )


def _resolve_target(config) -> str:
    return config.getoption("--target") or os.environ.get("SHED_TEST_TARGET") or "mac"


def pytest_configure(config):
    # Sync the resolved target back to the env BEFORE collection, so the mac-only
    # suites' module-level `@pytest.mark.skipif(... != "mac")` see the CLI flag
    # too (markers evaluate at import time, before any fixture exists).
    os.environ["SHED_TEST_TARGET"] = _resolve_target(config)


@pytest.fixture(scope="session")
def target(pytestconfig) -> str:
    return _resolve_target(pytestconfig)


@pytest.fixture(scope="session")
def mock():
    server = MockShedServer()
    server.start()
    yield server
    server.stop()


@pytest.fixture(scope="session")
def fake():
    """The fake host-agent backing the mac approval gate. Session-scoped and
    lazily instantiated — only the mac session (and its approval tests) request
    it, so a gtk run never starts it."""
    agent = FakeHostAgent()
    agent.start()
    yield agent
    agent.stop()


@pytest.fixture(scope="session", autouse=True)
def _app_session(mock, target, request):
    ui.quit(target)  # force-quit any running instance; we own a hermetic one
    # Short prefix: on macOS the socket lives under this dir (which is itself under
    # a long /var/folders TMPDIR), and a Unix socket path must stay under SUN_LEN.
    state_dir = Path(tempfile.mkdtemp(prefix=f"shed-e2e-{target}-"))
    # mac + tauri gate approvals → a fake host-agent; gtk has no approval spine.
    host_agent_socket = (
        request.getfixturevalue("fake").socket_path if target in _APPROVAL_TARGETS else None
    )
    if target == "mac":
        ui.launch(
            "mac",
            mock_base_url=mock.base_url,
            config_path=CONFIG,
            state_dir=state_dir,
            host_agent_socket=host_agent_socket,
        )
    else:
        # gtk + tauri are both subprocess targets with the same launch shape.
        ui.launch(target, mock_base_url=mock.base_url, config_path=CONFIG,
                  state_dir=state_dir, host_agent_socket=host_agent_socket)
        if target == "tauri":
            # The WebView mounts AFTER `identify`; wait for its first snapshot so no
            # test drives a backend op before the frontend can echo a refresh — the
            # cold-start window sheds.refresh's fast path only best-effort covers.
            c = TauriClient(ui.socket_path("tauri"))
            try:
                c.wait_until(lambda: c.current_pane() is not None, timeout=30,
                             what="tauri frontend ready")
            finally:
                c.close()
    yield
    ui.quit(target)


@pytest.fixture(autouse=True)
def _reset_policy(_app_session, target):
    """Reset to the default prompt+native-auth policy before each approval-capable
    test (policy is app state that persists across tests). gtk has no policy
    engine — no-op."""
    if target not in _APPROVAL_TARGETS:
        yield
        return
    c = ui.make_client(target)
    try:
        c.policy_set([{"scope": "default", "action": "prompt", "gate": "biometrics-or-password"}])
    finally:
        c.close()
    yield


@pytest.fixture(autouse=True)
def _reset_mock(mock, target, _app_session):
    """Each test starts from the default served payload. The gtk + tauri apps are
    session-scoped and their dashboard.dump reads last-rendered state, so those
    runs must ALSO re-sync the dashboard to the reset mock (a prior test's create/
    lifecycle mutation would otherwise leak into dashboard.dump); mac reads live."""
    mock.reset()
    if target in ("gtk", "tauri"):
        c = ui.make_client(target)
        try:
            c.sheds_refresh()
        finally:
            c.close()
    yield


@pytest.fixture
def shed(_app_session):
    """The mac app's full client. Used by the mac-only suites (skipped on gtk)."""
    client = ShedDesktop(ui.socket_path("mac"))
    try:
        yield client
    finally:
        client.close()


@pytest.fixture
def gtk(_app_session):
    """shed-gtk's client. Used by the gtk-only suite (skipped on mac)."""
    client = GtkClient(ui.socket_path("gtk"))
    try:
        yield client
    finally:
        client.close()


@pytest.fixture
def tauri(_app_session):
    """The Tauri client. Used by the tauri-only suite (skipped otherwise)."""
    client = TauriClient(ui.socket_path("tauri"))
    try:
        yield client
    finally:
        client.close()


@pytest.fixture
def client(_app_session, target):
    """The target-appropriate IPC client for the shared (cross-target) tests."""
    c = ui.make_client(target)
    try:
        yield c
    finally:
        c.close()
