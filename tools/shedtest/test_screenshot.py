"""M0: in-process screenshots of the window and the menu popover."""

from __future__ import annotations

import pytest
from client import ShedError

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def test_window_screenshot(shed):
    shed.show_window()
    png, w, h = shed.screenshot(surface="window", scale=2)
    assert png.startswith(PNG_MAGIC)
    assert w > 0 and h > 0
    metrics = shed.window_metrics()
    # 2x scale => pixel dims are ~2x the logical content size.
    assert abs(w - metrics["window_width"] * 2) <= 4
    assert abs(h - metrics["window_height"] * 2) <= 4


def test_menu_screenshot(shed):
    shed.open_menu(True)
    try:
        png, w, h = shed.screenshot(surface="menu", scale=1)
        assert png.startswith(PNG_MAGIC)
        assert w > 0 and h > 0
    finally:
        shed.open_menu(False)


def test_menu_screenshot_requires_open_menu(shed):
    shed.open_menu(False)
    with pytest.raises(ShedError) as exc:
        shed.screenshot(surface="menu")
    assert exc.value.code == "internal"
