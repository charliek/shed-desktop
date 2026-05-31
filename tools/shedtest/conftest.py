"""pytest fixtures for the ShedDesktop E2E suite.

A session fixture starts the in-process mock shed-server, then launches a
hermetic ShedDesktop.app pointed at it (test mode, throwaway state dir).
Each test gets a fresh `shed` IPC client and the shared `mock` so it can
mutate the served payload and force a poll.
"""

from __future__ import annotations

import tempfile
from pathlib import Path

import pytest
import ui
from client import ShedDesktop
from mockserver import MockShedServer

FIXTURES = Path(__file__).resolve().parent / "fixtures"


@pytest.fixture(scope="session")
def mock():
    server = MockShedServer()
    server.start()
    yield server
    server.stop()


@pytest.fixture(scope="session", autouse=True)
def _app_session(mock):
    ui.quit()  # force-quit any running instance; we own a hermetic one
    state_dir = Path(tempfile.mkdtemp(prefix="shed-desktop-e2e-"))
    ui.launch(
        mock_base_url=mock.base_url,
        config_path=FIXTURES / "config.yaml",
        state_dir=state_dir,
    )
    yield
    ui.quit()


@pytest.fixture
def shed(_app_session):
    client = ShedDesktop(ui.socket_path())
    try:
        yield client
    finally:
        client.close()


@pytest.fixture(autouse=True)
def _reset_mock(mock):
    """Each test starts from the default served payload."""
    mock.reset()
    yield
