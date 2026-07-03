"""gtk-only E2E: behavior specific to shed-gtk's runtime that has no macOS
analog — the tokio-task independence of the async bridge, and the single-
instance flock hand-off. Gated on `SHED_TEST_TARGET`, so the whole module is
skipped on `--target mac`.
"""

from __future__ import annotations

import os
import subprocess
import time

import pytest

import ui
from client import scaled_timeout

pytestmark = pytest.mark.skipif(
    os.environ.get("SHED_TEST_TARGET", "mac") != "gtk",
    reason="gtk-only: tokio-task independence + single-instance flock hand-off",
)


def test_sheds_list_during_create_no_deadlock(gtk):
    # A create in flight must not block sheds.list — they run as independent
    # tokio tasks. A regression (e.g. sharing one mutex/runtime) would wedge this.
    cid = gtk.create_start("concurrent")
    t0 = time.monotonic()
    sheds = gtk.sheds_list()
    assert time.monotonic() - t0 < scaled_timeout(5), \
        "sheds.list appears to have deadlocked during a create"
    assert isinstance(sheds, list)
    gtk.create_cancel(cid)


def test_second_launch_hands_off(gtk):
    # P3.3: a second shed-desktop against the same XDG_RUNTIME_DIR must detect the
    # running instance (flock the pidfile before binding), hand off by raising it
    # (an app.activate IPC), and exit 0 — never bind a second socket or leave a
    # process behind (which would risk unlinking the live instance's socket).
    proc = subprocess.Popen(
        [str(ui.BIN)], env=ui.gtk_launch_env(),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        rc = proc.wait(timeout=scaled_timeout(5))
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        pytest.fail("second shed-desktop did not exit within 5s — single-instance hand-off hung")
    assert rc == 0, f"second instance exited {rc}, want 0 (a clean flock hand-off)"

    # The first instance is untouched: its socket still answers identify...
    assert gtk.identify()["platform"] == "gtk"
    # ...and app.activate (the op the hand-off invoked) still succeeds.
    gtk.call("app.activate")
