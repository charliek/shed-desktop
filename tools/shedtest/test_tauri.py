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
from client import ShedError, scaled_timeout

pytestmark = pytest.mark.skipif(
    os.environ.get("SHED_TEST_TARGET", "mac") != "tauri",
    reason="tauri-only: single-instance hand-off + A0a UI ops",
)


def test_ui_ops_ack(tauri):
    # show_window + activate raise the window and ack (no frontend needed). Once the
    # frontend is ready, ui.navigate acks too. A raised error (non-`{}` envelope)
    # fails the call.
    tauri.show_window()
    tauri.activate()
    tauri.wait_until(lambda: tauri.current_pane() is not None, timeout=15, what="frontend ready")
    tauri.navigate("system")
    tauri.navigate("sheds")


def test_navigate_rejects_unknown_pane(tauri):
    # An unknown pane is a bad_request, not blindly emitted — a bogus pane would
    # otherwise blank the UI (PANES[pane] undefined).
    tauri.wait_until(lambda: tauri.current_pane() is not None, timeout=15, what="frontend ready")
    with pytest.raises(ShedError) as e:
        tauri.navigate("bogus")
    assert e.value.code == "bad_request"


def test_navigate_reports_rendered_pane(tauri):
    # A0b round-trip: ui.navigate emits `navigate` → React switches the pane and
    # reports it back (ui_report) → ui.current_pane reflects the RENDERED pane (the
    # dashboard.dump-is-UI-truth pattern). Proves the WebView is running the app.
    # current_pane becomes non-null only once the navigate listener is registered,
    # so this wait also rules out the listener-attach race.
    tauri.wait_until(lambda: tauri.current_pane() is not None, timeout=15, what="frontend ready")
    tauri.navigate("system")
    tauri.wait_until(lambda: tauri.current_pane() == "system", timeout=15, what="pane=system")
    tauri.navigate("agents")
    tauri.wait_until(lambda: tauri.current_pane() == "agents", timeout=15, what="pane=agents")


def test_computed_style_probe_confirms_theme(tauri):
    # The machine-checkable half of the WebKitGTK render gate: the WebView actually
    # applied the linen CSS, so the body background resolves to a real (non-
    # transparent) color. If oklch/color-mix failed to parse, the var-backed bg
    # would fall back to transparent (rgba(0, 0, 0, 0)).
    tauri.wait_until(lambda: (tauri.computed_style() or {}).get("bg"), timeout=15, what="computed style reported")
    style = tauri.computed_style()
    assert style["bg"], f"no body background reported: {style}"
    assert style["bg"] != "rgba(0, 0, 0, 0)", f"linen theme not applied (bg transparent): {style}"


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
