"""app.screenshot returns a non-empty PNG of the rendered window. Its acceptance
is deliberately only "a non-empty PNG of expected dimensions" so a hard gate
isn't coupled to the container's GL stack (dashboard.dump is the truth op)."""

_PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def test_screenshot_returns_non_empty_png(gtk):
    captured: dict = {}

    def grab() -> bool:
        # Raises GtkError ("window not realized") until the surface is up; the
        # wait_until retries until it succeeds.
        png, width, height = gtk.screenshot(scale=1)
        captured.update(png=png, width=width, height=height)
        return True

    gtk.wait_until(grab, timeout=20, what="window realized + screenshot")
    assert captured["png"][:8] == _PNG_MAGIC
    assert captured["width"] > 0 and captured["height"] > 0
