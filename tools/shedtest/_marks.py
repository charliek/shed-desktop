"""Target-gating pytest markers shared across the functional suites.

`pytest_configure` (conftest.py) syncs the resolved `--target` into
`$SHED_TEST_TARGET` before collection, so this module — imported at collection
time — sees the effective target whether it came from the CLI flag or the env.

- `mac_only`: the Swift app's ops (approvals / rc / nav / prefs / system / images
  / the surface-based screenshot) that neither shed-gtk nor Tauri implements.
- `needs_backend`: the shared-suite tests that drive the shed-core backend ops
  (sheds.list/refresh, the lifecycle actions, create + cancel). All three targets
  implement them now (Tauri gained them in A1b, on the shared shed-app Backend).
"""

from __future__ import annotations

import os

import pytest

_TARGET = os.environ.get("SHED_TEST_TARGET", "mac")

mac_only = pytest.mark.skipif(
    _TARGET != "mac",
    reason="mac-only: drives the Swift app op surface (no shed-gtk/tauri analog)",
)

# Targets whose UI implements the shed-core backend ops. All three do as of A1b.
_BACKEND_TARGETS = {"mac", "gtk", "tauri"}

needs_backend = pytest.mark.skipif(
    _TARGET not in _BACKEND_TARGETS,
    reason="target has no shed-core backend ops yet (tauri: lands in A1b)",
)
