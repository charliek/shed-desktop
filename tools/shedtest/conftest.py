"""pytest fixtures for the shed-desktop E2E suite (macOS app + shed-gtk).

Parameterized by `--target mac|gtk` (default `$SHED_TEST_TARGET`, else `mac`).
A session fixture starts the shared in-process mock shed-server, then launches a
hermetic UI for the chosen target and drives it over its IPC socket. The mac
target adds a fake host-agent (backing the approval gate) + a per-test policy
reset; the gtk target runs the shed-desktop subprocess with a throwaway HOME/
XDG_RUNTIME_DIR and re-syncs its (session-scoped) dashboard per test — the mac
fake-host-agent + policy machinery has no gtk analog and is not started there.

Shared tests take the `client` (target-appropriate) + `target` fixtures and run
on both; the mac-only suites gate on `SHED_TEST_TARGET` and are skipped on gtk.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

import ui
from client import GtkClient, ShedDesktop
from mockserver import MockShedServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fake-host-agent"))
from fake_host_agent import FakeHostAgent  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"
CONFIG = FIXTURES / "config.yaml"


def pytest_addoption(parser):
    parser.addoption(
        "--target", action="store", default=None, choices=list(ui.TARGETS),
        help="which UI to drive (mac|gtk); default $SHED_TEST_TARGET or mac",
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
    state_dir = Path(tempfile.mkdtemp(prefix=f"shed-desktop-e2e-{target}-"))
    if target == "mac":
        fake = request.getfixturevalue("fake")  # only the mac session needs it
        ui.launch(
            "mac",
            mock_base_url=mock.base_url,
            config_path=CONFIG,
            state_dir=state_dir,
            host_agent_socket=fake.socket_path,
        )
    else:
        ui.launch("gtk", mock_base_url=mock.base_url, config_path=CONFIG, state_dir=state_dir)
    yield
    ui.quit(target)


@pytest.fixture(autouse=True)
def _reset_policy(_app_session, target):
    """Reset to the default prompt+touchid policy before each mac test (policy
    is app state that persists across tests). gtk has no policy engine — no-op."""
    if target != "mac":
        yield
        return
    c = ShedDesktop(ui.socket_path("mac"))
    try:
        c.policy_set([{"scope": "default", "action": "prompt", "gate": "biometrics-or-password"}])
    finally:
        c.close()
    yield


@pytest.fixture(autouse=True)
def _reset_mock(mock, target, _app_session):
    """Each test starts from the default served payload. The gtk app is
    session-scoped and dashboard.dump reads last-rendered state, so a gtk run
    must ALSO re-sync the dashboard to the reset mock (a prior test's create/
    lifecycle mutation would otherwise leak into dashboard.dump); mac reads live."""
    mock.reset()
    if target == "gtk":
        c = GtkClient(ui.socket_path("gtk"))
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
def client(_app_session, target):
    """The target-appropriate IPC client for the shared (both-target) tests."""
    c = ShedDesktop(ui.socket_path("mac")) if target == "mac" else GtkClient(ui.socket_path("gtk"))
    try:
        yield c
    finally:
        c.close()
