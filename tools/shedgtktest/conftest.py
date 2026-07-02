"""pytest fixtures for the shed-gtk E2E suite.

A session fixture starts the shared in-process mock shed-server (reused from
tools/shedtest), then launches a hermetic shed-gtk pointed at it. Each test gets
a fresh IPC client. Run with `pytest tools/shedgtktest` (needs a display: the
native session on a Mac, `xvfb-run` on CI).
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import pytest

import ui
from client import GtkClient

REPO_ROOT = Path(__file__).resolve().parents[2]
# Reuse the shed-desktop in-process mock. Appended (not inserted) so this dir's
# own `ui`/`client` modules win over tools/shedtest's same-named ones.
sys.path.append(str(REPO_ROOT / "tools" / "shedtest"))
from mockserver import MockShedServer  # noqa: E402

# The GTK e2e reuses the Mac harness's fixture config (a single "mock" server).
FIXTURE_CONFIG = REPO_ROOT / "tools" / "shedtest" / "fixtures" / "config.yaml"


@pytest.fixture(scope="session")
def mock():
    server = MockShedServer()
    server.start()
    yield server
    server.stop()


@pytest.fixture(scope="session")
def app(mock):
    runtime = Path(tempfile.mkdtemp(prefix="shed-gtk-e2e-"))
    instance = ui.GtkApp(
        mock_base_url=mock.base_url, config_path=FIXTURE_CONFIG, runtime_dir=runtime
    )
    instance.launch()
    yield instance
    instance.quit()


@pytest.fixture
def gtk(app):
    client = GtkClient(app.socket_path)
    try:
        yield client
    finally:
        client.close()


@pytest.fixture(autouse=True)
def _reset_mock(mock):
    mock.reset()
    yield
