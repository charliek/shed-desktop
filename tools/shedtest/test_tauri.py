"""tauri-only E2E: behavior specific to the Tauri client's runtime that has no
mac/gtk analog — the single-instance hand-off, and the A0a UI ops (navigate /
show_window / activate) that aren't in the cross-target shared suite. Gated on
`SHED_TEST_TARGET`, so the whole module is skipped unless `--target tauri`.
"""

from __future__ import annotations

import os
import subprocess

import pytest

import ui
from client import scaled_timeout

pytestmark = pytest.mark.skipif(
    os.environ.get("SHED_TEST_TARGET", "mac") != "tauri",
    reason="tauri-only: single-instance hand-off + A0a UI ops",
)


def test_ui_ops_ack(tauri):
    # A0a: ui.navigate emits a `navigate` event to the frontend and acks;
    # show_window + activate raise the window and ack. No shared test drives
    # these; a raised error (non-`{}` envelope) fails the call.
    tauri.navigate("system")
    tauri.navigate("sheds")
    tauri.show_window()
    tauri.activate()


def test_second_launch_hands_off(tauri):
    # A second shed-desktop-tauri against the same runtime must detect the running
    # instance (the single-instance plugin), hand off by raising it, and exit —
    # never bind a second socket or leave a process behind.
    proc = subprocess.Popen(
        [str(ui.TAURI_BIN)], env=ui.launch_env("tauri"),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        rc = proc.wait(timeout=scaled_timeout(10))
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        pytest.fail("second shed-desktop-tauri did not exit within 10s — single-instance hand-off hung")
    assert rc == 0, f"second instance exited {rc}, want 0 (a clean single-instance hand-off)"

    # The first instance is untouched: its socket still answers identify...
    assert tauri.identify()["platform"] == "tauri"
    # ...and app.activate (the op the hand-off invoked) still succeeds.
    tauri.call("app.activate")
