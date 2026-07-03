"""Target-gating pytest markers shared by the mac-only suites.

`pytest_configure` (conftest.py) syncs the resolved `--target` into
`$SHED_TEST_TARGET` before collection, so this module — imported at collection
time — sees the effective target whether it came from the CLI flag or the env.
The mac-only suites drive the Swift app's ops (approvals / rc / nav / prefs /
system / images / the surface-based screenshot) that shed-gtk doesn't implement;
they set `pytestmark = mac_only` so a `--target gtk` run skips them cleanly.
"""

from __future__ import annotations

import os

import pytest

_TARGET = os.environ.get("SHED_TEST_TARGET", "mac")

mac_only = pytest.mark.skipif(
    _TARGET != "mac",
    reason="mac-only: drives the Swift app op surface (no shed-gtk analog)",
)
